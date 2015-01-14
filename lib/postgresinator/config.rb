namespace :postgresinator do

  desc 'Write example config files'
  task :write_example_configs do
    run_locally do
      execute "mkdir", "-p", "config/deploy", fetch(:postgres_templates_path)
      {
        'examples/Capfile'                    => 'Capfile_example',
        'examples/config/deploy.rb'           => 'config/deploy_example.rb',
        'examples/config/deploy/staging.rb'   => 'config/deploy/staging_example.rb',
        'examples/Dockerfile'                 => "#{fetch(:postgres_templates_path)}/Dockerfile_example",
        'examples/postgresql.conf.erb'        => "#{fetch(:postgres_templates_path)}/postgresql_example.conf.erb",
        'examples/pg_hba.conf.erb'            => "#{fetch(:postgres_templates_path)}/pg_hba_example.conf.erb",
        'examples/recovery.conf.erb'          => "#{fetch(:postgres_templates_path)}/recovery_example.conf.erb"
      }.each do |source, destination|
        config = File.read(File.dirname(__FILE__) + "/#{source}")
        File.open("./#{destination}", 'w') { |f| f.write(config) }
        info "Wrote '#{destination}'"
      end
      info "Now remove the '_example' portion of their names or diff with existing files and add the needed lines."
    end
  end

  desc 'Write a file showing the built-in overridable settings'
  task :write_built_in do
    run_locally do
      {
        'built-in.rb'                         => 'built-in.rb',
      }.each do |source, destination|
        config = File.read(File.dirname(__FILE__) + "/#{source}")
        File.open("./#{destination}", 'w') { |f| f.write(config) }
        info "Wrote '#{destination}'"
      end
      info "Now examine the file and copy anything you want to customize into your deploy.rb or <stage>.rb."
    end
  end

end
