namespace :pg do

  task :ensure_setup => ['pg:check:settings', 'deployinator:sshkit_umask'] do |t, args|
    Rake::Task['pg:check:settings:database'].invoke(args.database_name) unless args.database_name.nil?
    Rake::Task['pg:check:settings:domain'].invoke(args.domain) unless args.domain.nil?
  end

  desc "Idempotently setup one or more PostgreSQL instances and their databases."
  task :setup => [:ensure_setup, 'deployinator:deployment_user', 'pg:check:firewalls'] do
    Rake::Task['pg:install_config_files'].invoke
    Rake::Task['pg:check:file_permissions'].invoke
    on roles(:db) do |host|
      unless container_exists?(host.properties.postgres_container_name)
        fatal_message = "#{fetch(:postgres_data_path)} on #{host} is not empty, cannot continue! " +
          "You'll need to delete those files by hand. Be sure you are not deleting important data!"
        fatal fatal_message and exit if files_in_directory?(fetch(:postgres_data_path))
        execute("docker", "run", fetch(:postgres_docker_init_command))
        create_container(host.properties.postgres_container_name, fetch(:postgres_docker_run_command))
      else
        unless container_is_running?(host.properties.postgres_container_name)
          start_container(host.properties.postgres_container_name)
        else
          if host.properties.config_file_changed
            restart_container(host.properties.postgres_container_name)
          else
            info("No config file changes for #{host.properties.postgres_container_name}" +
              "on #{host} and it is already running; we're setup!")
          end
        end
      end
      master_container_running = false
      master_container_running = container_is_running?(host.properties.postgres_container_name)
      # sleep to allow postgres to start up before running subsequent commands against it
      sleep 3
      unless pg_role_exists?("replicator")
        info "Creating postgres role 'replicator'."
        pg_create_role("replicator", fetch(:postres_replicator_pass))
      end
    end
    on roles(:db_slave) do |host|
      unless container_exists?(host.properties.postgres_container_name)
        fatal "Master must be running before creating a slave" and exit unless master_container_running
        fatal_message = "#{fetch(:postgres_data_path)} on #{host} is not empty, cannot continue! " +
          "You'll need to delete those files by hand. Be sure you are not deleting important data!"
        fatal fatal_message and exit if files_in_directory?(fetch(:postgres_data_path))
        #execute("rm", "#{fetch(:postgres_data_path)}/*", "-rf")
        execute("docker", "run", fetch(:postgres_docker_replicate_command))
        create_ssl_keys unless file_exists?(fetch(:postgres_ssl_key))
        install_recovery_conf
        create_container(host.properties.postgres_container_name, fetch(:postgres_docker_run_command))
      else
        unless container_is_running?(host.properties.postgres_container_name)
          start_container(host.properties.postgres_container_name)
        else
          if host.properties.config_file_changed
            restart_container(host.properties.postgres_container_name)
          else
            info("No config file changes for #{host.properties.postgres_container_name}" +
              "on #{host} and it is already running; we're setup!")
          end
        end
      end
    end
    Rake::Task['pg:db:setup'].invoke
  end

  desc "Check the statuses of each PostgreSQL instance in the cluster."
  task :status => :ensure_setup do
    on roles(:db, :db_slave) do |host|
      if container_exists?(server)
        if container_is_running?(host.properties.postgres_container_name)
          info "#{host.properties.postgres_container_name} exists and is running on #{host}"
        else
          info "#{host.properties.postgres_container_name} exists on #{host} but is not running."
        end
      else
        info "#{host.properties.postgres_container_name} does not exist on #{host}"
      end
    end
  end

  task :install_config_files => ['deployinator:deployment_user', 'deployinator:sshkit_umask'] do
    require 'erb' unless defined?(ERB)
    on roles(:db, :db_slave) do |host|
      host.properties.set :config_file_changed, false
      as 'root' do
        execute "mkdir", "-p", fetch(:postgres_config_path)
        fetch(:postgres_config_files).each do |config_file|
          template_path = File.expand_path("#{fetch(:postgres_templates_path)}/#{config_file}.erb")
          generated_config_file = ERB.new(File.new(template_path).read).result(binding)
          upload! StringIO.new(generated_config_file), "/tmp/#{config_file}.file"
          unless test "diff", "-q", "/tmp/#{config_file}.file", "#{fetch(:postgres_config_path)}/#{config_file}"
            warn "Config file #{config_file} on #{host} is being updated."
            execute("mv", "/tmp/#{config_file}.file", "#{fetch(:webserver_config_path)}/#{config_file}")
            host.properties.set :config_file_changed, true
          else
            execute "rm", "/tmp/#{config_file}.file"
          end
        end
        execute("chown", "-R", "root:root", fetch(:postgres_config_path))
        execute "find", fetch(:postgres_config_path), "-type", "d", "-exec", "chmod", "2775", "{}", "+"
        execute "find", fetch(:postgres_config_path), "-type", "f", "-exec", "chmod", "0660", "{}", "+"
      end
    end
  end

  def install_recovery_conf
    as 'root' do
      path = "#{fetch(:postgres_data_path)}/recovery.conf"
      template_path = File.expand_path("#{fetch(:postgres_templates_path)}/recovery.conf.erb")
      ERB.new(File.new(template_path).read).result(binding)
      generated_config_file = pg_generate_config_file(cluster, server, args.config_file)
      upload! StringIO.new(generated_config_file), "/tmp/recovery_conf"
      execute("mv", "/tmp/recovery_conf", path)
      execute("chown", "-R", "#{fetch(:postgres_uid)}:#{fetch(:postgres_gid)}", path)
      execute("chmod", "700", path)
    end
  end

  def create_ssl_keys
    as "root" do
      execute("docker", "run", fetch(:postgres_docker_csr_command))
      execute("docker", "run", fetch(:postgres_docker_crt_command))
    end
  end

end
