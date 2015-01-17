namespace :pg do

  task :ensure_setup => ['pg:check:settings', 'deployinator:sshkit_umask'] do |t, args|
    SSHKit.config.output_verbosity = fetch(:postgres_log_level)
    Rake::Task['pg:check:settings:database'].invoke(args.database_name) unless args.database_name.nil?
    Rake::Task['pg:check:settings:domain'].invoke(args.domain) unless args.domain.nil?
  end

  desc "Idempotently setup one or more PostgreSQL instances and their databases."
  task :setup => [:ensure_setup, 'postgresinator:deployment_user', 'pg:check:firewall', 'pg:check:settings:postgres_uid_gid'] do
    Rake::Task['pg:install_config_files'].invoke
    on roles(:db) do |host|
      name = host.properties.postgres_container_name
      if container_exists?(name)
        existing_container_start_or_restart_if_needed(host)
      else
        fatal_message = "#{fetch(:postgres_data_path)} on #{host} is not empty, cannot continue! " +
          "You'll need to delete those files by hand. Be sure you are not deleting important data!"
        as :root do
          fatal fatal_message and exit if files_in_directory?(fetch(:postgres_data_path))
        end
        pg_init(host)
        install_ssl_key_crt(host)
        warn "Starting a new container named #{name} on #{host}"
        pg_run(host)
        check_stayed_running(name)
      end
      set :master_container_running,  false
      set :master_container_running,  container_is_running?(name)
      set :master_container_port,     host.properties.postgres_port
      # sleep to allow postgres to start up before running subsequent commands against it
      sleep 3
      unless pg_role_exists?("replicator")
        info "Creating postgres role 'replicator'."
        pg_create_role("replicator", fetch(:postgres_replicator_pass))
      end
    end
    on roles(:db_slave, :in => :parallel) do |host|
      name = host.properties.postgres_container_name
      unless container_exists?(name)
        fatal "Master must be running before creating a slave" and exit unless fetch(:master_container_running)
        fatal_message = "#{fetch(:postgres_data_path)} on #{host} is not empty, cannot continue! " +
          "You'll need to delete those files by hand. Be sure you are not deleting important data!"
        as :root do
          fatal fatal_message and exit if files_in_directory?(fetch(:postgres_data_path))
        end
        pg_replicate(host)
        install_ssl_key_crt(host)
        install_recovery_conf
        warn "Starting a new container named #{name} on #{host}"
        pg_run(host)
        check_stayed_running(name)
      else
        existing_container_start_or_restart_if_needed(host)
      end
    end
    Rake::Task['pg:db:setup'].invoke
  end

  desc "Check the statuses of each PostgreSQL instance."
  task :status => [:ensure_setup, 'postgresinator:deployment_user'] do
    on roles(:db, :db_slave, :in => :sequence) do |host|
      name = host.properties.postgres_container_name
      if container_exists?(name)
        if container_is_running?(name)
          info "#{name} exists and is running on #{host}"
        else
          info "#{name} exists on #{host} but is not running."
        end
      else
        info "#{name} does not exist on #{host}"
      end
    end
  end

  task :install_config_files => [:ensure_setup, 'postgresinator:deployment_user'] do
    require 'erb' unless defined?(ERB)
    on roles(:db, :db_slave, :in => :parallel) do |host|
      host.properties.set :config_file_changed, false
      as 'root' do
        execute "mkdir", "-p", fetch(:postgres_config_path)
        fetch(:postgres_config_files).each do |config_file|
          template_path = File.expand_path("#{fetch(:postgres_templates_path)}/#{config_file}.erb")
          generated_config_file = ERB.new(File.new(template_path).read).result(binding)
          upload! StringIO.new(generated_config_file), "/tmp/#{config_file}.file"
          unless test "diff", "-q", "/tmp/#{config_file}.file", "#{fetch(:postgres_config_path)}/#{config_file}"
            warn "Config file #{config_file} on #{host} is being updated."
            execute("cp", "/tmp/#{config_file}.file", "#{fetch(:postgres_config_path)}/#{config_file}")
            host.properties.set :config_file_changed, true
          end
          execute "rm", "/tmp/#{config_file}.file"
        end
      end
    end
  end

  def install_ssl_key_crt(host)
    as 'root' do
      [fetch(:postgres_ssl_key), fetch(:postgres_ssl_crt)].each do |file|
        if test("[", "-L", file, "]") or file_exists?(file)
          execute("rm", file)
        end
      end
      pg_ssl_key(host)
      pg_ssl_crt(host)
      execute("rm", fetch(:postgres_ssl_csr))
      execute("chmod", "0600", fetch(:postgres_ssl_key))
      execute("chmod", "0600", fetch(:postgres_ssl_crt))
      [fetch(:postgres_ssl_key), fetch(:postgres_ssl_crt)].each do |file|
        execute("chown", "#{fetch(:postgres_uid)}:#{fetch(:postgres_gid)}", file)
        execute("chmod", "0600", file)
      end
    end
  end

  def install_recovery_conf
    as 'root' do
      path = "#{fetch(:postgres_data_path)}/recovery.conf"
      template_path = File.expand_path("#{fetch(:postgres_templates_path)}/recovery.conf.erb")
      generated_config_file = ERB.new(File.new(template_path).read).result(binding)
      upload! StringIO.new(generated_config_file), "/tmp/recovery_conf"
      execute("mv", "/tmp/recovery_conf", path)
      execute("chown", "#{fetch(:postgres_uid)}:#{fetch(:postgres_gid)}", path)
      execute("chmod", "0640", path)
    end
  end

  def existing_container_start_or_restart_if_needed(host)
    name = host.properties.postgres_container_name
    if container_is_running?(name)
      if container_is_restarting?(name)
        restart_container(name)
      elsif host.properties.config_file_changed
        ask_reload_or_restart(name, host)
      else
        info("No config file changes for #{name} " +
             "on #{host} and it is already running; we're setup!")
      end
    else
      start_container(name)
    end
  end

  def ask_reload_or_restart(name, host)
    warn "A config file has changed for #{name} on #{host}, please specify " +
      "whether you would like to have PostgreSQL reload the config, or restart itself"
    ask :reload_or_restart, nil
    case fetch(:reload_or_restart).chomp.downcase
    when "reload"
      execute("docker", "kill", "-s", "SIGHUP", name)
    when "restart"
      restart_container(name)
    else
      warn "Please enter 'reload' or 'restart'"
      ask_reload_or_restart(name, host)
    end
  end

end
