namespace :postgresinator do

  desc 'Write example config files'
  task :write_example_configs do
    run_locally do
      execute "mkdir", "-p", "config/deploy", "templates/postgresql"
      {
        'examples/Capfile'                                  => 'Capfile_example',
        'examples/config/deploy.rb'                         => 'config/deploy_example.rb',
        'examples/config/deploy/staging.rb'                 => 'config/deploy/staging_example.rb',
        'examples/Dockerfile'                               => 'templates/postgresql/Dockerfile_example',
        'examples/postgresql.conf.erb'                      => 'templates/postgresql/postgresql_example.conf.erb',
        'examples/pg_hba.conf.erb'                          => 'templates/postgresql/pg_hba_example.conf.erb',
        'examples/recovery.conf.erb'                        => 'templates/postgresql/recovery_example.conf.erb'
      }.each do |source, destination|
        config = File.read(File.dirname(__FILE__) + "/#{source}")
        File.open("./#{destination}", 'w') { |f| f.write(config) }
        info "Wrote '#{destination}'"
      end
      info "Now remove the '_example' portion of their names or diff with existing files and add the needed lines."
    end
  end

end
