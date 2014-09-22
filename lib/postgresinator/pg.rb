require './postgresinator.rb'

namespace :pg do

  desc "Setup one or more PostgreSQL instances based on a json file"
  task :setup => :load_settings do
    Rake::Task["pg:ensure_access_docker"].invoke
    Rake::Task["pg:upload_config_files"].invoke
    @clusters.each do |cluster|
      cluster.servers.each do |server|
        on "#{ENV["USER"]}@#{server.domain}" do |host|
          if exists?(server) and is_running?(server)
            restart = false
          else
            restart = true
          end
          cluster.config_files.each do |config_file|
            within '/tmp' do
              as 'root' do
                unless test "diff", config_file, "/#{server.container_name}-conf/#{config_file}"
                  execute("mkdir", "-p", "/#{server.container_name}-conf")
                  execute("mkdir", "-p", "/#{server.container_name}-data")
                  execute("mv", "-b", config_file, "/#{server.container_name}-conf/#{config_file}")
                  execute("chown", "-R", "102:105", "/#{server.container_name}-conf")
                  execute("chown", "-R", "102:105", "/#{server.container_name}-data")
                  execute("chmod", "700", "/#{server.container_name}-conf")
                  execute("chmod", "700", "/#{server.container_name}-data")
                  restart = true
                end
              end
            end
          end
          restart_postgres(cluster, server) if restart
          ensure_role(cluster, server, "replicator") if server.master
        end
      end
    end
  end

  desc "Check the status of one or more PostgreSQL instances"
  task :status => :load_settings do
    @clusters.each do |cluster|
      cluster.servers.each do |server|
        on "#{ENV["USER"]}@#{server.domain}" do |host|
          if exists?(server)
            info "#{server.container_name} exists on #{server.domain}"
            if is_running?(server)
              info "#{server.container_name} is running on #{server.domain}"
              info("Streaming status of #{server.container_name} on #{server.domain}:\n" + streaming_status(cluster, server)) if server.master
            else
              info "#{server.container_name} is not running on #{server.domain}"
            end
          else
            info "#{server.container_name} does not exist on #{server.domain}"
          end
        end
      end
    end
  end


  private

    task :load_settings do
      @clusters = Hashie::Mash.new(PostgresClusters.settings).clusters
      @clusters.each do |cluster|
        cluster.servers.each do |server|
          if server.master
            server.container_name = "#{server.domain}-postgres-master"
          else
            master_domain = cluster.servers.collect { |s| s.domain if s.master }
            server.container_name = "#{master_domain[0]}-postgres-slave"
          end
        end
      end
      Rake::Task["pg:ensure_clusters_data_uniquenesses"].invoke
    end

    # TODO: get this working for multiple clusters
    task :ensure_clusters_data_uniquenesses do
      @clusters.each do |cluster|
        names = cluster.servers.collect { |s| s.container_name }
        fatal "The container names in this cluster are not unique" unless names == names.uniq
      end
    end

    task :upload_config_files do
      @clusters.each do |cluster|
        cluster.servers.each do |server|
          on "#{ENV["USER"]}@#{server.domain}" do
            cluster.config_files.each do |config_file|
              @server = server
              @cluster = cluster
              template_path = File.expand_path("templates/#{config_file}.erb")
              host_config   = ERB.new(File.new(template_path).read).result(binding)
              upload! StringIO.new(host_config), "/tmp/#{config_file}"
            end
          end
        end
      end
    end

    task :ensure_access_docker do
      @clusters.each do |cluster|
        cluster.servers.each do |server|
          on "#{ENV["USER"]}@#{server.domain}" do
            unless test("docker", "ps")
              execute("sudo", "usermod", "-a", "-G", "docker", "#{ENV["USER"]}")
              fatal "Newly added to docker group, this run will fail, next run will succeed. Simply try again."
            end
          end
        end
      end
    end

    def streaming_status(cluster, server)
      capture "echo", "\"select", "*", "from", "pg_stat_replication;\"", "|",
        "docker", "run", "--rm ", "--interactive",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image_name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p $POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'"
    end

    def restart_postgres(cluster, server)
      if exists?(server)
        if is_running?(server)
          warn "Restarting a running container named #{server.container_name}"
          execute("docker", "restart", server.container_name)
        else
          warn "Starting an existing but non-running container named #{server.container_name}"
          execute("docker", "start", server.container_name)
        end
      else
        warn "Starting a new container named #{server.container_name}"
        as 'root' do
          execute("docker", "run", server.docker_run_command)
        end
      end
      sleep 2
      fatal("Container #{server.container_name} on #{server.domain} did not stay running more than 2 seconds!") and exit unless is_running?(server)
    end

    def exists?(server)
      test "docker", "inspect", server.container_name
    end

    def is_running?(server)
      (capture "docker", "inspect",
        "--format='{{.State.Running}}'",
        server.container_name).strip == "true"
    end

    def ensure_role(cluster, server, role)
      unless test "echo", "\"SELECT", "*", "FROM", "pg_user", "WHERE", "usename", "=", "'#{role}';\"", "|",
        "docker", "run", "--rm", "--interactive",
        "--entrypoint", "/bin/bash",
        "--link", "#{server.container_name}:postgres", cluster.image_name,
        "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'", "|",
        "grep", "-q", role
        execute("echo", "\"CREATE", "ROLE", role,
          "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{role}'", "CREATEDB;\"", "|",
          "docker", "run", "--rm", "--interactive",
          "--entrypoint", "/bin/bash",
          "--link", "#{server.container_name}:postgres", cluster.image_name,
          "-c", "'/usr/bin/psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'")
      end
    end
end
