Gem::Specification.new do |s|
  s.name        = 'postgresinator'
  s.version     = '0.3.1'
  s.date        = '2016-03-23'
  s.summary     = "Deploy PostgreSQL"
  s.description = "Deploy PostgreSQL instances using Capistrano and Docker"
  s.authors     = ["david amick"]
  s.email       = "davidamick@ctisolutionsinc.com"
  s.files       = [
    "lib/postgresinator.rb",
    "lib/postgresinator/built-in.rb",
    "lib/postgresinator/check.rb",
    "lib/postgresinator/config.rb",
    "lib/postgresinator/db.rb",
    "lib/postgresinator/pg.rb",
    "lib/postgresinator/examples/Dockerfile",
    "lib/postgresinator/examples/Capfile",
    "lib/postgresinator/examples/config/deploy.rb",
    "lib/postgresinator/examples/config/deploy/staging.rb",
    "lib/postgresinator/examples/postgresql.conf.erb",
    "lib/postgresinator/examples/pg_hba.conf.erb",
    "lib/postgresinator/examples/recovery.conf.erb"
  ]
  s.required_ruby_version   =               '>= 1.9.3'
  s.requirements            <<              "Docker ~> 1.3.1"
  s.add_runtime_dependency  'capistrano',   '~> 3.2.1'
  s.add_runtime_dependency  'deployinator', '~> 0.1.6'
  s.add_runtime_dependency  'rake',         '~> 10.3.2'
  s.add_runtime_dependency  'sshkit',       '~> 1.5.1'
  s.homepage                =
    'https://github.com/snarlysodboxer/postgresinator'
  s.license                 = 'GNU'
end
