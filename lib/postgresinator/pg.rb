require 'erb'

require './postgresinator.rb' if File.exists?('./postgresinator.rb')

## NOTES:
# tasks without 'desc' description lines are for manual debugging of this
#   deployment code.
#
# we've choosen to only pass strings (if anything) to tasks. this allows tasks to be
#   debugged individually. only private methods take ruby objects.

namespace :pg do

  task :ensure_setup => ['config:load_settings', 'config:ensure_cluster_data_uniqueness'] do |t, args|
    # use 'rake pg:COMMAND debug=true' for debugging (you can also add --trace if you like)
    SSHKit.config.output_verbosity = Logger::DEBUG if ENV['debug'] == "true"
    Rake::Task['config:config_file_not_found'].invoke(args.config_file) unless args.config_file.nil?
    Rake::Task['config:database_not_found'].invoke(args.database_name) unless args.database_name.nil?
    Rake::Task['config:domain_not_found'].invoke(args.domain) unless args.domain.nil?
    Rake::Task['config:role_not_found'].invoke(args.role_name) unless(args.role_name.nil? or args.force == "true")
  end

  desc "Idempotently setup one or more PostgreSQL instances using values in ./postgresinator.rb"
  task :setup => :ensure_setup do
    # instance variables are lost inside SSHKit's 'on' block, so
    #   at the beginning of each task we assign cluster to @cluster.
    cluster = @cluster
    cluster.servers.each do |server|
      Rake::Task['pg:ensure_access_docker'].invoke(server.domain)
      Rake::Task['pg:ensure_access_docker'].reenable
      Rake::Task['pg:open_firewall'].invoke(server.domain)
      Rake::Task['pg:open_firewall'].reenable
      # 'on', 'run_locally', 'as', 'execute', 'info', 'warn', and 'fatal' are from SSHKit
      on "#{cluster.ssh_user}@#{server.domain}" do
        config_file_changed = false
        cluster.image.config_files.each do |config_file|
          next if config_file == "recovery.conf"
          if pg_config_file_differs?(cluster, server, config_file)
            warn "Config file #{config_file} on #{server.domain} is being updated."
            Rake::Task['pg:install_config_file'].invoke(server.domain, config_file)
            Rake::Task['pg:install_config_file'].reenable
            config_file_changed = true
          end
        end
        unless pg_container_exists?(server)
          # the create_container task's prerequisite task :ensure_config_files is
          #   for manual use of create_container, so here we clear_prerequisites.
          Rake::Task['pg:create_container'].clear_prerequisites
          Rake::Task['pg:create_container'].invoke(server.domain)
          Rake::Task['pg:create_container'].reenable
        else
          unless pg_container_is_running?(server)
            Rake::Task['pg:start_container'].invoke(server.domain)
            Rake::Task['pg:start_container'].reenable
          else
            if config_file_changed
              Rake::Task['pg:restart_container'].invoke(server.domain)
              Rake::Task['pg:restart_container'].reenable
            else
              info "No config file changes for #{server.container_name} and it is already running; we're setup!"
            end
          end
        end
        # sleep to allow postgres to start up before running subsequent commands against it
        sleep 3
        if server.master
          unless pg_role_exists?(cluster, server, "replicator")
            info "Creating role 'replicator' #{server.domain}"
            Rake::Task['pg:create_role'].invoke(server.domain, "replicator")
            Rake::Task['pg:create_role'].reenable
          end
          cluster.databases.each do |database|
            unless pg_role_exists?(cluster, server, database.role)
              info "Creating role #{database.role} on #{server.domain}"
              Rake::Task['pg:create_role'].invoke(server.domain, database.role)
              Rake::Task['pg:create_role'].reenable
            end
            unless pg_database_exists?(cluster, server, database)
              info "Creating database #{database.name} on #{server.domain}"
              Rake::Task['pg:create_database'].invoke(server.domain, database.name)
              Rake::Task['pg:create_database'].reenable
              Rake::Task['pg:grant_database'].invoke(server.domain, database.name)
              Rake::Task['pg:grant_database'].reenable
            end
          end
        end
      end
    end
  end

  desc "Check the statuses of each PostgreSQL instance in the cluster."
  task :statuses => :ensure_setup do
    cluster = @cluster
    cluster.servers.each do |server|
      Rake::Task['pg:status'].invoke(server.domain)
      Rake::Task['pg:status'].reenable
    end
  end

  desc "Check the status of the PostgreSQL instance on 'domain'."
  task :status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      if pg_container_exists?(server)
        info "#{server.container_name} exists on #{server.domain}"
        if pg_container_is_running?(server)
          info ""
          info "#{server.container_name} is running on #{server.domain}"
          info ""
          Rake::Task['pg:list_roles'].invoke(server.domain)
          Rake::Task['pg:list_roles'].reenable
          info ""
          Rake::Task['pg:list_databases'].invoke(server.domain)
          Rake::Task['pg:list_databases'].reenable
          info ""
          Rake::Task['pg:streaming_status'].invoke(server.domain)
          Rake::Task['pg:streaming_status'].reenable
        else
          info "#{server.container_name} is not running on #{server.domain}"
        end
      else
        info "#{server.container_name} does not exist on #{server.domain}"
      end
    end
  end

  desc "Restore 'dump_file' in /tmp on the master server into 'database_name'."
  task :restore, [:dump_file, :database_name]  => :ensure_setup do |t, args|
    cluster = @cluster
    database = cluster.databases.select { |d| d.name == args.database_name }.first
    # we only restore on the master server
    server = cluster.servers.select { |s| s.master }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      if server.master
        clean = ""
        unless pg_database_empty?(cluster, server, database)
          if pg_confirm_database_overwrite?(server, database); clean = "--clean"; else exit(0); end
        end
        execute("docker", "run", "--rm",
          "--volume", "/tmp:/tmp:rw",
          "--entrypoint", "/bin/bash",
          "--volumes-from", server.container_name,
          cluster.image.name,
          "-c", "'/usr/bin/pg_restore", "-U", "postgres", clean,
          "-d", database.name, "-F", "tar", "-v", "/tmp/#{args.dump_file}'"
        )
      end
    end
  end

  desc "Dump 'database_name' into /tmp/'dump_file' on the master server."
  task :dump, [:dump_file, :database_name]  => :ensure_setup do |t, args|
    cluster = @cluster
    database = cluster.databases.select { |d| d.name == args.database_name }.first
    # we only dump from the master server
    server = cluster.servers.select { |s| s.master }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      if server.master
        pg_confirm_file_overwrite?(server, args.dump_file) if pg_file_exists?("/tmp/#{args.dump_file}")
        execute("docker", "run", "--rm",
          "--volume", "/tmp:/tmp:rw",
          "--entrypoint", "/bin/bash",
          "--volumes-from", server.container_name,
          cluster.image.name,
          "-c", "'/usr/bin/pg_dump", "-U", "postgres", "-F", "tar",
          "-v", database.name, ">", "/tmp/#{args.dump_file}'"
        )
      end
    end
  end

  desc "Print the command to enter psql interactive mode on 'domain'."
  task :print_interactive, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    run_locally do
      info "You can paste the following command into a terminal on #{server.domain} to enter psql interactive mode for #{server.container_name}:"
      info "docker run --rm --interactive --tty --volumes-from #{server.container_name} --entrypoint /bin/bash #{cluster.image.name} -lic '/usr/bin/psql -U postgres'"
    end
  end

  task :ensure_config_files, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      cluster.image.config_files.each do |config_file|
        next if config_file == "recovery.conf"
        if pg_config_file_differs?(cluster, server, config_file)
          Rake::Task['pg:install_config_file'].invoke(server.domain, config_file)
          Rake::Task['pg:install_config_file'].reenable
        end
      end
    end
  end

  task :create_container, [:domain] => :ensure_config_files do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    master_server = cluster.servers.select { |s| s.master }.first
    unless server.master
      on "#{cluster.ssh_user}@#{master_server.domain}" do
        fatal "Master must be running before creating a slave" and raise unless pg_container_is_running?(master_server)
      end
    end
    on "#{cluster.ssh_user}@#{server.domain}" do
      warn "Starting a new container named #{server.container_name} on #{server.domain}"
      as 'root' do
        fatal_message = "#{server.data_path} on #{server.domain} is not empty, cannot continue! " +
          "You'll need to delete those files by hand. Be sure you are not deleting important data!"
        fatal fatal_message and raise if pg_files_in_data_path?(server)
        execute("mkdir", "-p", server.data_path) unless test("test", "-d", server.data_path)
        execute("chown", "-R", "#{cluster.image.postgres_uid}:#{cluster.image.postgres_gid}", server.data_path)
        execute("chmod", "700", server.data_path)
        execute("docker", "run", server.docker_init_command)
        unless server.master
          execute("rm", "#{server.data_path}/*", "-rf")
          execute("docker", "run", server.docker_replicate_command)
          Rake::Task['pg:link_keys'].invoke(server.domain)
          Rake::Task['pg:link_keys'].reenable
          Rake::Task['pg:install_config_file'].invoke(server.domain, "recovery.conf")
          Rake::Task['pg:install_config_file'].reenable
        end
        execute("docker", "run", server.docker_run_command)
      end
    end
  end

  task :restart_container, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      warn "Restarting a running container named #{server.container_name}"
      execute("docker", "restart", server.container_name)
      sleep 2
      fatal pg_stay_running_message(server) and raise unless pg_container_is_running?(server)
    end
  end

  task :start_container, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{server.domain}" do
      warn "Starting an existing but non-running container named #{server.container_name}"
      execute("docker", "start", server.container_name)
      sleep 2
      fatal pg_stay_running_message(server) and raise unless pg_container_is_running?(server)
    end
  end

  task :ensure_access_docker, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    on "#{cluster.ssh_user}@#{args.domain}" do
      as cluster.ssh_user do
        unless test("bash", "-c", "\"docker", "ps", "&>", "/dev/null\"")
          execute("sudo", "usermod", "-a", "-G", "docker", cluster.ssh_user)
          fatal "Newly added to docker group, this run will fail, next run will succeed. Simply try again."
        end
      end
    end
  end

  task :install_config_file, [:domain, :config_file] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      as 'root' do
        # TODO: get this recovery.conf dependancy out of here?
        path = args.config_file == "recovery.conf" ? server.data_path : server.conf_path
        execute("mkdir", "-p", path) unless test("test", "-d", path)
        generated_config_file = pg_generate_config_file(cluster, server, args.config_file)
        upload! StringIO.new(generated_config_file), "/tmp/#{args.config_file}"
        execute("mv", "/tmp/#{args.config_file}", "#{path}/#{args.config_file}")
        execute("chown", "-R", "#{cluster.image.postgres_uid}:#{cluster.image.postgres_gid}", path)
        execute("chmod", "700", path)
      end
    end
  end

  task :list_roles, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      capture("docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--volumes-from", server.container_name,
        cluster.image.name,
        "-c", "'/usr/bin/psql", "-U", "postgres",
        "-c", "\"\\du\"'").each_line { |line| info line }
    end
  end

  task :list_databases, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      capture("docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--volumes-from", server.container_name,
        cluster.image.name,
        "-c", "'/usr/bin/psql", "-U", "postgres",
        "-a", "-c", "\"\\l\"'").each_line { |line| info line }
    end
  end

  task :streaming_status, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      if server.master
        info "Streaming status of #{server.container_name} on #{server.domain}:"
        capture("echo", "\"SELECT", "*", "FROM", "pg_stat_replication;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--volumes-from", server.container_name,
          cluster.image.name,
          "-c", "'/usr/bin/psql", "-U", "postgres", "-xa'").each_line { |line| info line }
      else
        # TODO: fix this for slave servers
        info "Streaming status of #{server.container_name} on #{server.domain}:"
        capture("echo", "\"SELECT", "now()", "-", "pg_last_xact_replay_timestamp()",
          "AS", "replication_delay;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--volumes-from", server.container_name,
          cluster.image.name,
          "-c", "'/usr/bin/psql", "-U", "postgres'").each_line { |line| info line }
      end
    end
  end

  task :create_role, [:domain, :role_name, :force] => :ensure_setup do |t, args|
    args.with_defaults :force => "false"
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      execute("echo", "\"CREATE", "ROLE", "\\\"#{args.role_name}\\\"",
        "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{args.role_name}'",
        "REPLICATION", "CREATEDB;\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--volumes-from", server.container_name,
        cluster.image.name,
        "-c", "'/usr/bin/psql", "-U", "postgres'")
    end
  end

  task :create_database, [:domain, :database_name] => :ensure_setup do |t, args|
    cluster = @cluster
    database = cluster.databases.select { |d| d.name == args.database_name }.first
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      execute("echo", "\"CREATE", "DATABASE", "\\\"#{database.name}\\\"",
        "WITH", "OWNER", "\\\"#{database.role}\\\"", "TEMPLATE",
        "template0", "ENCODING", "'UTF8';\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--volumes-from", server.container_name,
        cluster.image.name,
        "-c", "'/usr/bin/psql", "-U", "postgres'")
    end
  end

  task :grant_database, [:domain, :database_name] => :ensure_setup do |t, args|
    cluster = @cluster
    database = cluster.databases.select { |d| d.name == args.database_name }.first
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      execute("echo", "\"GRANT", "ALL", "PRIVILEGES", "ON", "DATABASE",
        "\\\"#{database.name}\\\"", "to", "\\\"#{database.role}\\\";\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--volumes-from", server.container_name,
        cluster.image.name,
        "-c", "'/usr/bin/psql", "-U", "postgres'")
    end
  end

  task :link_keys, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      as "root" do
        inner_server_crt = "#{cluster.image.data_path}/server.crt"
        outer_server_crt = "#{server.data_path}/server.crt"
        unless pg_file_exists?(outer_server_crt)
          execute("docker", "run",
            "--rm", "--user", "root", "--entrypoint", "/bin/ln",
            "--volume", "#{server.data_path}:#{cluster.image.data_path}:rw",
            cluster.image.name, "-s", "/etc/ssl/certs/ssl-cert-snakeoil.pem", inner_server_crt
          )
          execute("chown", "root.", outer_server_crt)
        end
        inner_server_key = "#{cluster.image.data_path}/server.key"
        outer_server_key = "#{server.data_path}/server.key"
        unless pg_file_exists?(outer_server_key)
          execute("docker", "run",
            "--rm", "--user", "root", "--entrypoint", "/bin/ln",
            "--volume", "#{server.data_path}:#{cluster.image.data_path}:rw",
            cluster.image.name, "-s", "/etc/ssl/private/ssl-cert-snakeoil.key", inner_server_key
          )
          execute("chown", "root.", outer_server_key)
        end
      end
    end
  end

  task :open_firewall, [:domain] => :ensure_setup do |t, args|
    cluster = @cluster
    server = cluster.servers.select { |s| s.domain == args.domain }.first
    on "#{cluster.ssh_user}@#{args.domain}" do
      as "root" do
        if test "ufw", "status"
          raise "Error during opening UFW firewall" unless test("ufw", "allow", "#{server.port}/tcp")
        end
      end
    end
  end

  private

    # Temporarily added 'pg_' to the beginning of each of these methods to avoid
    #   getting them overwritten by other gems with methods with the same names, (E.G. nginxinator.)
    ## TODO Figure out how to do this the right or better way.
    def pg_stay_running_message(server)
      "Container #{server.container_name} on #{server.domain} did not stay running more than 2 seconds"
    end

    def pg_files_in_data_path?(server)
      test("[", "\"$(ls", "-A", "#{server.data_path})\"", "]")
    end

    def pg_config_file_differs?(cluster, server, config_file)
      generated_config_file = pg_generate_config_file(cluster, server, config_file)
      as 'root' do
        if pg_file_exists?("#{server.conf_path}/#{config_file}")
          capture("cat", "#{server.conf_path}/#{config_file}").chomp != generated_config_file.chomp
        else
          true
        end
      end
    end

    def pg_generate_config_file(cluster, server, config_file)
      @cluster      = cluster # needed for ERB
      @server       = server  # needed for ERB
      template_path = File.expand_path("templates/postgresql/#{config_file}.erb")
      ERB.new(File.new(template_path).read).result(binding)
    end

    def pg_role_exists?(cluster, server, role)
      test("echo", "\"SELECT", "*", "FROM", "pg_user", "WHERE", "usename", "=", "'#{role}';\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--volumes-from", server.container_name,
        cluster.image.name,
        "-c", "'/usr/bin/psql", "-U", "postgres'", "|",
        "grep", "-q", "'#{role}'")
    end

    def pg_database_exists?(cluster, server, database)
      test "docker", "run", "--rm",
        "--entrypoint", "/bin/bash",
        "--volumes-from", server.container_name,
         cluster.image.name,
        "-c", "'/usr/bin/psql", "-U", "postgres", "-lqt", "|",
        "cut", "-d\\|", "-f1", "|", "grep", "-w", "#{database.name}'"
    end

    def pg_container_exists?(server)
      test "docker", "inspect", server.container_name, ">", "/dev/null"
    end

    def pg_container_is_running?(server)
      (capture "docker", "inspect",
        "--format='{{.State.Running}}'",
        server.container_name).strip == "true"
    end

    def pg_file_exists?(file_name_path)
      test "[", "-f", file_name_path, "]"
    end

    def pg_confirm_file_overwrite?(server, dump_file)
      warn "A file named #{dump_file} already exists on #{server.domain} in /tmp. If you continue, you will overwrite it."
      warn "Are you positive(Y/N)?"
      STDOUT.flush
      case STDIN.gets.chomp.upcase
      when "Y"
        true
      when "N"
        false
      else
        warn "Please enter Y or N"
        pg_confirm_file_overwrite?(server, dump_file)
      end
    end

    def pg_confirm_database_overwrite?(server, database)
      warn "There is already data in #{database.name} on #{server.domain} in the container " +
        "#{server.container_name} which stores it's data in #{server.data_path} on the host."
      warn "If you continue, you must be positive you want to overwrite the existing data."
      warn "Are you positive(Y/N)?"
      STDOUT.flush
      case STDIN.gets.chomp.upcase
      when "Y"
        true
      when "N"
        false
      else
        warn "Please enter Y or N"
        pg_confirm_database_overwrite?(server, database)
      end
    end

    def pg_database_empty?(cluster, server, database)
      test("docker", "run", "--rm", "--volumes-from", server.container_name,
        "--entrypoint", "/bin/bash", cluster.image.name, "-lc",
        "'/usr/bin/psql", "-U", "postgres", "-d", database.name,
        "-c", "\"\\dt\"", "|", "grep", "-qi", "\"no relations found\"'")
    end
end
