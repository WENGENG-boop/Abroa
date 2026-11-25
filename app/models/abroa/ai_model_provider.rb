require "uri"
require "ipaddr"

module Abroa
  # User-owned OpenAI-compatible endpoint; API key uses Rails authenticated
  # Active Record encryption and is never emitted in response JSON/logs.
  class AiModelProvider < ApplicationRecord
    self.table_name = "abroa_ai_model_providers"
    Conflict = Class.new(StandardError)
    CAPABILITY_FIELDS = %w[chat_completions tool_calls responses_api timeout_seconds max_output_tokens].freeze
    DEFAULT_MAX_OUTPUT_TOKENS = 16_384
    MAX_OUTPUT_TOKENS = 393_216
    DEFAULT_TIMEOUT_SECONDS = 120
    MAX_TIMEOUT_SECONDS = 600

    belongs_to :family
    belongs_to :owner, class_name: "User"
    encrypts :api_key

    validates :base_url, :model_identifier, presence: true
    validate :valid_scope
    validate :validated_config

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      where(owner_id: user.id, family_id: user.family_id)
    end

    def self.configure_for!(user, attributes:, key:)
      attrs = attributes.to_h.symbolize_keys
      raise ArgumentError, "Unknown provider field" if (attrs.keys -
        %i[base_url api_key model_name capabilities]).any?
      raise ArgumentError, "Invalid idempotency key" unless key.is_a?(String) &&
        key.bytesize.between?(1, 128)
      base = validated_url!(attrs.fetch(:base_url))
      model = model_name!(attrs.fetch(:model_name))
      secret = secret!(attrs.fetch(:api_key))
      caps = capabilities!(attrs[:capabilities] || {})
      request = Digest::SHA256.hexdigest([ base, model, caps.sort.to_h, secret ].to_json)
      key_digest = Digest::SHA256.hexdigest(key)

      StudyProject.with_actor(user) do
        old = for_user(user).first
        if old
          raise Conflict, "Provider already configured with different key" unless
            old.setup_key_digest == key_digest && old.setup_request_digest == request
          next old
        end
        create!(owner: user, family: user.family,
          base_url: base, model_identifier: model, api_key: secret,
          capabilities: caps, setup_key_digest: key_digest,
          setup_request_digest: request)
      end
    end

    def update_for!(actor, version:, attributes:)
      attrs = attributes.to_h.symbolize_keys
      raise ArgumentError, "Unknown provider field" if (attrs.keys -
        %i[base_url api_key model_name capabilities disabled]).any?
      self.class.transaction do
        lock!
        ensure_owner!(actor)
        raise Conflict, "Provider version changed" unless version.is_a?(Integer) && lock_version == version
        self.base_url = self.class.validated_url!(attrs[:base_url]) if attrs.key?(:base_url)
        self.model_identifier = self.class.model_name!(attrs[:model_name]) if attrs.key?(:model_name)
        self.api_key = self.class.secret!(attrs[:api_key]) if attrs.key?(:api_key)
        self.capabilities = self.class.capabilities!(attrs[:capabilities]) if attrs.key?(:capabilities)
        if attrs.key?(:disabled)
          raise ArgumentError, "Expected boolean" unless attrs[:disabled] == true || attrs[:disabled] == false
          self.disabled = attrs[:disabled]
        end
        save!
        PlanningAuditEvent.record!(actor: actor, event_type: "ai_provider.updated", resource: self,
          safe_data: { disabled: disabled, model: model_identifier })
        self
      end
    end

    def disable_for!(actor)
      self.class.transaction do
        lock!
        ensure_owner!(actor)
        update!(disabled: true)
        PlanningAuditEvent.record!(actor: actor, event_type: "ai_provider.disabled", resource: self)
        self
      end
    end

    def encrypted_api_key
      read_attribute_before_type_cast("api_key")
    end

    def inspect
      "#<Abroa::AiModelProvider id=#{id} owner_id=#{owner_id} model_identifier=#{model_identifier.inspect} key=[REDACTED]>"
    end

    def payload
      { id: id, base_url: base_url, model_name: model_identifier,
        api_key_configured: api_key.present?, api_key_masked: api_key.present? ? "••••#{api_key.last(4)}" : nil,
        disabled: disabled, capabilities: capabilities, lock_version: lock_version,
        updated_at: updated_at&.utc&.iso8601(6) }
    end

    # Only a self-hosted administrator can preapprove exact private IPv4
    # endpoints for local models. This is deliberately not a user preference.
    def self.local_approved_url?(value)
      return false unless Rails.application.config.app_mode.self_hosted?
      allowlist = ENV.fetch("ABROA_AI_ALLOWED_LOCAL_ENDPOINTS", "").split(",").map(&:strip)
      return false unless allowlist.include?(value)
      uri = URI.parse(value)
      return false unless %w[http https].include?(uri.scheme) &&
        uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
        uri.host.present? && uri.port.between?(1, 65_535)
      ip = IPAddr.new(uri.host)
      return false unless ip.ipv4? && (ip.loopback? || ip.private?)
      path = uri.path.presence || "/"
      path.start_with?("/") && path.length <= 160 && !path.match?(/\.{2}|%|\\\\/)
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      false
    end

    def self.validated_url!(value)
      raise ArgumentError, "Invalid endpoint length" unless
        value.is_a?(String) && value.bytesize.between?(1, 350) &&
        value.ascii_only? && !value.match?(/[\r\n\t\s\\]/)
      uri = URI.parse(value)
      return value if local_approved_url?(value)
      raise ArgumentError, "HTTPS required" unless uri.is_a?(URI::HTTPS)
      raise ArgumentError, "No embedded credentials, query or fragment" if
        uri.userinfo || uri.query || uri.fragment
      host = uri.host.to_s.downcase
      raise ArgumentError, "Only public hostname is supported" unless
        host.length.between?(4, 253) && host.include?(".") &&
        host.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/) &&
        host.split(".").all? { |label| label.length <= 63 } &&
        !host.end_with?(".local", ".localhost", ".internal", ".test", ".invalid") &&
        host != "metadata.google.internal" &&
        !host.match?(/\A\d+(?:\.\d+){3}\z/) &&
        !host.include?("..")
      begin
        IPAddr.new(host)
        raise ArgumentError, "IP address endpoints are disabled"
      rescue IPAddr::InvalidAddressError
        # A public DNS hostname is permitted; the resolved IP must be pinned
        # and independently vetted at the moment the connection is opened.
      end
      path = uri.path.presence || "/"
      raise ArgumentError, "Unsafe path" if path.match?(/\.\.|%2[eEfF]|%5[cC]/) ||
        !path.start_with?("/") || path.length > 160
      base = "https://#{host}"
      base += ":#{uri.port}" if uri.port != 443
      base + (path == "/" ? "" : path.sub(%r{/\z}, ""))
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid HTTPS endpoint"
    end

    def self.model_name!(value)
      raise ArgumentError, "Invalid model name" unless value.is_a?(String) &&
        value.bytesize.between?(1, 128) && value.match?(/\A[A-Za-z0-9_.\/+:\-]+\z/)
      value
    end

    def self.secret!(value)
      raise ArgumentError, "Invalid API key" unless value.is_a?(String) &&
        value.bytesize.between?(8, 2048) && !value.match?(/[\r\n\0]/)
      value
    end

    def self.capabilities!(value)
      raise ArgumentError, "Invalid capability options" unless value.is_a?(Hash)
      data = value.stringify_keys
      raise ArgumentError, "Unknown capability" if (data.keys - CAPABILITY_FIELDS).any?
      %w[chat_completions tool_calls responses_api].each do |key|
        next unless data.key?(key)
        raise ArgumentError, "Expected boolean capability" unless [ true, false ].include?(data[key])
      end
      if data.key?("timeout_seconds")
        raise ArgumentError, "Invalid timeout" unless data["timeout_seconds"].is_a?(Integer) &&
          data["timeout_seconds"].between?(5, MAX_TIMEOUT_SECONDS)
      end
      if data.key?("max_output_tokens")
        raise ArgumentError, "Invalid output limit" unless data["max_output_tokens"].is_a?(Integer) &&
          data["max_output_tokens"].between?(32, MAX_OUTPUT_TOKENS)
      end
      { "chat_completions" => true, "timeout_seconds" => DEFAULT_TIMEOUT_SECONDS,
        "max_output_tokens" => DEFAULT_MAX_OUTPUT_TOKENS }.merge(data)
    end

    private
      def ensure_owner!(actor)
        raise ActiveRecord::RecordNotFound unless actor&.active? &&
          actor.id == owner_id && actor.family_id == family_id
      end

      def valid_scope
        errors.add(:owner, :invalid) unless owner && owner.family_id == family_id
      end

      def validated_config
        self.class.validated_url!(base_url)
        self.class.model_name!(model_identifier)
        self.class.capabilities!(capabilities)
      rescue ArgumentError
        errors.add(:base, "Invalid provider configuration")
      end
  end
end
