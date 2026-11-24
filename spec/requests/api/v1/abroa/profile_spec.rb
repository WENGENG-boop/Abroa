# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Abroa profile and onboarding', type: :request do
  let(:family) { Family.create!(name: 'Abroa docs', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y') }
  let(:user) { family.users.create!(email: 'abroa-docs@example.com', password: 'password123', password_confirmation: 'password123') }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'API Docs Key', key: key, scopes: %w[read_write], source: 'web')
  end
  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/abroa/profile' do
    get 'Read own Abroa preferences' do
      tags 'Abroa'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Preferences (defaults when not yet saved)' do
        schema '$ref' => '#/components/schemas/AbroaProfileResponse'
        run_test!
      end
    end

    patch 'Update own Abroa preferences' do
      tags 'Abroa'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaProfileUpdate' }
      response '200', 'Updated' do
        schema '$ref' => '#/components/schemas/AbroaProfileResponse'
        let(:body) { { student_enabled: true, parent_enabled: true, mode: 'custom', lock_version: 0 } }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/onboarding' do
    get 'Read onboarding state' do
      tags 'Abroa'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Current state' do
        schema '$ref' => '#/components/schemas/AbroaOnboardingResponse'
        run_test!
      end
    end

    patch 'Change onboarding step' do
      tags 'Abroa'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false, required: %w[step lock_version],
        properties: {
          step: { type: :string, enum: %w[role region preferences review] },
          lock_version: { type: :integer, minimum: 0 }
        }
      }
      response '200', 'Updated' do
        schema '$ref' => '#/components/schemas/AbroaOnboardingResponse'
        let!(:profile) { Abroa::Profile.change_for!(user, version: 0, attributes: { student_enabled: true }) }
        let(:body) { { step: 'review', lock_version: profile.lock_version } }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/onboarding/complete' do
    post 'Complete onboarding idempotently' do
      tags 'Abroa'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: 'Idempotency-Key', in: :header, required: true, schema: { type: :string, maxLength: 128 }
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false, required: %w[lock_version],
        properties: { lock_version: { type: :integer, minimum: 0 } }
      }
      response '200', 'Completed or replayed' do
        schema '$ref' => '#/components/schemas/AbroaOnboardingResponse'
        let!(:profile) { Abroa::Profile.change_for!(user, version: 0, attributes: { parent_enabled: true }) }
        let(:'Idempotency-Key') { 'abroa-docs-complete' }
        let(:body) { { lock_version: profile.lock_version } }
        run_test!
      end
    end
  end
end
