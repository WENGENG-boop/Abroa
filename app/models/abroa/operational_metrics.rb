class Abroa::OperationalMetrics
  InvalidWindow = Class.new(StandardError)
  MAX_DAYS = 366

  attr_reader :from_date, :to_date, :start_at, :end_at

  def initialize(from: nil, to: nil)
    @to_date = to.present? ? parse_date!(to) : Time.current.utc.to_date
    @from_date = from.present? ? parse_date!(from) : 29.days.ago.utc.to_date
    today = Time.current.utc.to_date
    raise InvalidWindow, "Time window must be 1–366 days and cannot scan the future" if
      from_date > to_date || (to_date - from_date).to_i >= MAX_DAYS ||
      to_date > today + 1 || from_date.year < 2010

    @start_at = Time.utc(from_date.year, from_date.month, from_date.day)
    following = to_date.next_day
    @end_at = Time.utc(following.year, following.month, following.day)
  end

  def users
    registered = User.where(created_at: time_range).count
    active = User.where(last_login_at: time_range).count
    mature_end = [ end_at - 7.days, Time.current - 7.days ].min
    matured = mature_end > start_at ? User.where(created_at: start_at...mature_end) : User.none
    mature_count = matured.count
    retained = mature_count.zero? ? 0 :
      matured.where("last_login_at >= users.created_at + INTERVAL '7 days'").count

    base("users", registered).merge(
      registrations: { count: registered, denominator: registered,
        source: "users.created_at" },
      active_accounts: { count: active, denominator: User.count,
        definition: "last_login_at within UTC window",
        source: "users.last_login_at" },
      retention_7d: { count: retained, eligible_denominator: mature_count,
        rate: percentage(retained, mature_count),
        definition: "cohort from registration window, last login at least 7 days after registration",
        immature_cohorts_excluded: true }
    )
  end

  def banks
    scope = Sync.where(syncable_type: "Account", created_at: time_range)
    statuses = scope.group(:status).count.stringify_keys
    total = statuses.values.sum
    terminal = %w[completed failed stale].sum { |state| statuses.fetch(state, 0) }
    completed = statuses.fetch("completed", 0)
    configured = Abroa::OperationalConfig.where(category: "bank_provider")
      .pluck(:code, :settings)
    coverage = configured.flat_map do |_name, value|
      value.is_a?(Hash) ? Array(value["regions"]) : []
    end.uniq.sort

    base("syncs", total).merge(
      domain: "banks", completed: completed,
      statuses: statuses, completed_rate: percentage(completed, terminal),
      completed_denominator: terminal,
      unfinalized_count: total - terminal,
      error_categories: { failed: statuses.fetch("failed", 0),
        stale: statuses.fetch("stale", 0), unknown_error_count: statuses.fetch("failed", 0) },
      registered_provider_count: configured.size,
      configured_region_coverage: coverage,
      cost_amount: nil, cost_currency: nil,
      cost_source: "unknown; Sync does not store verified provider charges",
      definition: "Account Sync rows; completed / (completed + failed + stale)"
    )
  end

  def ai
    scope = Abroa::AiModelUsage.where(created_at: time_range)
    statuses = scope.group(:status).count.stringify_keys
    total = statuses.values.sum
    known = scope.where.not(cost_usd: nil)
    known_count = known.count
    configured_models = Abroa::OperationalConfig.where(category: "ai_model")
      .pluck(:code, :settings)
      .map { |code, settings| { code: code, status: settings["status"] || "unknown",
        enabled: settings["enabled"] } }

    base("abroa_ai_model_usages", total).merge(
      domain: "ai", statuses: statuses,
      success_rate: percentage(statuses.fetch("success", 0), total),
      success_denominator: total,
      input_tokens: scope.sum(:input_tokens), output_tokens: scope.sum(:output_tokens),
      known_cost_sample_size: known_count, unknown_cost_count: total - known_count,
      cost_amount: known_count.positive? ? known.sum(:cost_usd).to_s("F") : nil,
      cost_currency: known_count.positive? ? "USD" : nil,
      cost_source: "abroa_ai_model_usages.cost_usd",
      configured_models: configured_models,
      definition: "Completed P4 AI usage records, not raw messages or owner model names"
    )
  end

  def imports
    scope = Import.where(created_at: time_range)
    statuses = scope.group(:status).count.stringify_keys
    total = statuses.values.sum
    # Names of importer classes are implementation metadata; never return
    # original file names, raw upload bytes, parser inputs or error messages.
    templates = Abroa::OperationalConfig.where(category: "import_template")
      .pluck(:code, :settings)
      .map do |code, settings|
        { code: code, version: settings["version"], status: settings["status"] }
      end

    finished_count = %w[complete completed failed errored].sum { |state| statuses.fetch(state, 0) }
    complete_count = %w[complete completed].sum { |state| statuses.fetch(state, 0) }
    base("imports", total).merge(
      domain: "imports", statuses: statuses,
      completion_rate: percentage(complete_count, finished_count),
      completion_denominator: finished_count,
      diagnostic_categories: {
        failed: statuses.fetch("failed", 0) + statuses.fetch("errored", 0),
        stuck: statuses.fetch("processing", 0) + statuses.fetch("pending", 0)
      },
      configured_templates: templates,
      definition: "Import status only; uploaded files, parser diagnostics and contents excluded"
    )
  end

  def self.health
    checked_at = Time.current.utc.iso8601(6)
    database = begin
      ok = ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1
      { status: ok ? "healthy" : "degraded" }
    rescue StandardError
      { status: "unavailable" }
    end

    redis = begin
      ping = Timeout.timeout(2) { Sidekiq.redis { |conn| conn.ping } }
      { status: ping.to_s.upcase == "PONG" ? "healthy" : "degraded" }
    rescue StandardError
      { status: "unavailable" }
    end

    worker = begin
      metrics = Timeout.timeout(2) do
        stats = Sidekiq::Stats.new
        { queued_count: stats.enqueued, busy_count: stats.workers_size,
          retry_count: stats.retry_size,
          scheduled_count: stats.scheduled_size, dead_count: stats.dead_size }
      end
      metrics.merge(status: "observed", source: "Sidekiq::Stats, Redis")
    rescue StandardError
      { status: "unavailable", source: "Sidekiq::Stats, Redis",
        queued_count: nil, busy_count: nil, retry_count: nil,
        scheduled_count: nil, dead_count: nil }
    end
    {
      checked_at: checked_at, source: "live_database_redis_sidekiq_probes",
      database: database, redis: redis, sidekiq: worker,
      scheduler: { scheduled_queue_size: worker[:scheduled_count],
        last_successful_tick: nil, tick_status: "unknown" },
      sample_size: 1
    }
  end

  private

    def parse_date!(value)
      raise InvalidWindow, "Dates must use YYYY-MM-DD" unless value.is_a?(String) &&
        value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      Date.iso8601(value)
    rescue Date::Error, ArgumentError
      raise InvalidWindow, "Invalid ISO date"
    end

    def time_range
      start_at...end_at
    end

    def base(source, sample)
      {
        window_start: start_at.iso8601(6), window_end: end_at.iso8601(6),
        interval: "[window_start, window_end) UTC",
        sampled_at: Time.current.utc.iso8601(6),
        sample_size: sample, source: source,
        unknown_values_are_null: true
      }
    end

    def percentage(numerator, denominator)
      return nil if denominator.zero?
      (BigDecimal(numerator.to_s) / denominator * 100).round(2).to_s("F")
    end
end
