# frozen_string_literal: true

require_relative 'factories'

require 'ashttp'
require "uri"
require "json"
require "digest"
require "rspec"
require 'rspec/retry'
require 'test_utils'
require 'config/config-distribution'
require 'securerandom'
require 'axe-rspec'
require 'nokogiri'

require_relative '../../indexer/app/lib/pui_indexer'

if ENV['COVERAGE_REPORTS'] == 'true'
  require 'aspace_coverage'
  ASpaceCoverage.start('public:test', 'rails')
end

require 'aspace_gems'

$server_pids = []
$backend_port = TestUtils::free_port_from(3636)
$frontend_port = TestUtils::free_port_from(4545)
$backend = ENV['ASPACE_TEST_BACKEND_URL'] || "http://localhost:#{$backend_port}"
$test_db_url = ENV['ASPACE_TEST_DB_URL'] || AppConfig[:db_url]
$frontend = "http://localhost:#{$frontend_port}"
$expire = 30000

AppConfig[:backend_url] = $backend
AppConfig[:pui_hide][:record_badge] = false # we want this for testing

$backend_start_fn = proc {
  TestUtils::start_backend($backend_port,
                           {
                             :session_expire_after_seconds => $expire,
                             :realtime_index_backlog_ms => 600000,
                             :db_url => $test_db_url
                           })
}

module IndexTestRunner
  def run_indexers
    @@period ||= PeriodicIndexer.new($backend)
    @@pui ||= PUIIndexer.new($backend)
    @@period.run_index_round
    @@pui.run_index_round
  end
end

ENV['RAILS_ENV'] ||= 'test'
require File.expand_path('../../config/environment', __FILE__)
require 'rspec/rails'
include FactoryBot::Syntax::Methods

def setup_test_data
  repo = create(:repo, :repo_code => "test_#{Time.now.to_i}", publish: true)
  set_repo repo

  digi_obj = create(:digital_object, title: 'Born digital', publish: true)

  subject = create(:subject, title: 'Subject')

  create(:agent_person,
         names: [build(:name_person,
                       name_order: 'direct',
                       primary_name: "Agent",
                       rest_of_name: "Published",
                       sort_name: "Published Agent",
                       number: nil,
                       dates: nil,
                       qualifier: nil,
                       fuller_form: nil,
                       prefix: nil,
                       title: nil,
                       suffix: nil)],
         dates_of_existence: nil,
         publish: true)

  pa = create(:accession, title: "Published Accession", publish: true, instances: [
    build(:instance_digital, digital_object: { 'ref' => digi_obj.uri })
  ])
  ua = create(:accession, title: "Unpublished Accession", publish: false, instances: [
    build(:instance_digital, digital_object: { 'ref' => digi_obj.uri })
  ])

  create(:accession_with_deaccession, title: "Published Accession with Deaccession")
  create(:accession, title: "Accession for Phrase Search")


  create(:accession, title: "Accession with Relationship",
                     publish: true,
                     related_accessions: [
                        build(:accession_parts_relationship, ref: pa.uri),
                        build(:accession_parts_relationship, ref: ua.uri)
                     ])

  create(:accession, title: "Accession with Deaccession", publish: true,
    deaccessions: [build(:json_deaccession)])

  create(:accession, title: "Accession with Lang/Script",
                     publish: true,
                     language: 'eng',
                     script: 'Latn')

  create(:accession, title: "Accession with Lang Material Note",
                     publish: true,
                     lang_materials: [
                        build(:lang_material_with_note)
                     ])

  create(:accession, title: "Accession without Lang Material Note",
                     publish: true,
                     lang_materials: [
                        build(:lang_material)
                     ])

  resource = create(:resource, title: "Published Resource",
                    publish: true,
                    instances: [build(:instance_digital)],
                    subjects: [{'ref' => subject.uri}])

  create(:resource, title: "Resource with Deaccession", publish: true,
    deaccessions: [build(:json_deaccession)])

  create(:resource, title: "Resource with Accession", publish: true,
    related_accessions: [{'ref' => pa.uri}])


  classification = create(:classification, :title => "My Special Classification")
  create(:digital_object, title: "Digital Object With Classification",
                          classifications: [{'ref' => classification.uri}])

  aos = (0..5).map do
    create(:archival_object,
           title: "Published Archival Object", resource: { 'ref' => resource.uri }, publish: true)
  end

  unpublished_resource = create(:resource, title: "Unpublished Resource", publish: false)
  unp_aos = (0..5).map do
    create(:archival_object,
           resource: { 'ref' => unpublished_resource.uri }, publish: true)
  end
  create(:resource, title: "Resource for Phrase Search", publish: true)
  create(:resource, title: "Search as Phrase Resource", publish: true)

  resource_with_scope = create(:resource_with_scope, title: "Resource with scope note", publish: true)
  aos = (0..5).map do
    create(:archival_object,
           resource: { 'ref' => resource_with_scope.uri }, publish: true)
  end
end

RSpec.configure do |config|

  config.include FactoryBot::Syntax::Methods
  config.include BackendClientMethods
  config.include IndexTestRunner

  # show retry status in spec process
  config.verbose_retry = true
  # Try thrice (retry twice)
  config.default_retry_count = 3

  [:controller, :view, :request].each do |type|
    config.include ::Rails::Controller::Testing::TestProcess, :type => type
    config.include ::Rails::Controller::Testing::TemplateAssertions, :type => type
    config.include ::Rails::Controller::Testing::Integration, :type => type
  end

  config.before(:suite) do
    if ENV['ASPACE_TEST_BACKEND_URL']
      puts "Running tests against #{$backend}"
    else
      puts "Starting backend using #{$backend}"
      $server_pids << $backend_start_fn.call
    end
    ArchivesSpaceClient.init
    $admin = BackendClientMethods::ASpaceUser.new('admin', 'admin')
    AspaceFactories.init
    setup_test_data unless ENV['ASPACE_TEST_SKIP_FIXTURES']
    PeriodicIndexer.new($backend).run_index_round
    PUIIndexer.new($backend).run_index_round
  end

  config.after(:suite) do
    $server_pids.each do |pid|
      TestUtils::kill(pid)
    end
    # For some reason we have to manually shutdown mizuno for the test suite to
    # quit.
    Rack::Handler.get('mizuno').instance_variable_get(:@server) ? Rack::Handler.get('mizuno').instance_variable_get(:@server).stop : next
  end
end
