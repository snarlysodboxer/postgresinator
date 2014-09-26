Gem::Specification.new do |s|
  s.name        = 'postgresinator'
  s.version     = '0.0.0'
  s.date        = '2014-09-19'
  s.summary     = "Deploy PostgreSQL"
  s.description = "An Opinionated PostgreSQL Deployment gem"
  s.authors     = ["david amick"]
  s.email       = "davidamick@ctisolutionsinc.com"
  s.files       = [
    "lib/postgresinator.rb",
    "lib/postgresinator/pg.rb",
    "lib/postgresinator/config.rb",
    "lib/postgresinator/examples/postgresinator_example.rb",
    "lib/postgresinator/examples/postgresql_example.conf.erb",
    "lib/postgresinator/examples/pg_hba_example.conf.erb",
    "lib/postgresinator/examples/recovery_example.conf.erb"
  ]
  s.add_runtime_dependency 'rake',        '= 10.3.2'
  s.add_runtime_dependency 'sshkit',      '= 1.5.1'
  s.add_runtime_dependency 'hashie',      '= 3.2.0'
  s.homepage    =
    'http://rubygems.org/gems/postgresinator'
  s.license       = 'MIT'
end
