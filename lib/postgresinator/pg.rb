require './postgresinator.rb'

namespace :pg do
  desc "Setup one or more PostgreSQL instances based on a json file"
  task :setup do
    cluster = Hashie::Mash.new(PostgresClusters.settings)
    ensure_cluster_data_uniquenesses(cluster)
    cluster.servers.each do |server|
      server.cluster = cluster
      on "#{ENV["USER"]}@#{server.domain}" do |host|
        ensure_access_docker
        if exists?(server) and is_running?(server)
          restart = false
        else
          restart = true
        end
        upload_config_files(server)
        config_files(server).each do |template, config_file|
          within '/tmp' do
            unless test "diff", config_file, "/#{server.domain}-#{server.container_name}-conf/#{config_file}"
              as 'root' do
                execute "mkdir", "-p", "/#{server.domain}-#{server.container_name}-conf"
                execute "mv", "-b", config_file, "/#{server.domain}-#{server.container_name}-conf/#{config_file}"
              end
              restart = true
            end
          end
        end
        restart_postgres(server) if restart
        ensure_role(server, "replicator") if server.master
      end
    end
  end

  desc "Check the status of one or more PostgreSQL instances based on a json file"
  task :status do
    cluster = Hashie::Mash.new(PostgresClusters.settings)
    ensure_cluster_data_uniquenesses(cluster)
    cluster.servers.each do |server|
      server.cluster = cluster
      on "#{ENV["USER"]}@#{server.domain}" do |host|
        if exists?(server)
          info "#{server.container_name} exists"
          if is_running?(server)
            info "#{server.container_name} is running"
            info("Streaming status:\n" + streaming_status(server)) if server.master
          else
            info "#{server.container_name} is not running"
          end
        else
          info "#{server.container_name} does not exist"
        end
      end
    end
  end


  private
    def streaming_status(server)
      capture "echo", "\"select", "*", "from", "pg_stat_replication;\"", "|",
        "docker", "run", "--rm ", "--interactive",
        "--link", "#{server.container_name}:postgres", server.cluster.image_name,
        "bash", "-c", "'exec", "psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'"
    end

    def ensure_cluster_data_uniquenesses(cluster)
      names = cluster.servers.collect { |s| s.container_name }
      fatal "The container names in this cluster are not unique" unless names == names.uniq

      ports = cluster.servers.collect do |server|
        if server.publish
          server.publish_port
        end
      end
      fatal "The published port numbers in this cluster are not unique" unless ports == ports.uniq
    end

    def config_files(server)
      { server.cluster.postgres_conf => "postgresql.conf",
        server.cluster.pg_hba_conf   => "pg_hba.conf"
      }
    end

    def upload_config_files(server)
      config_files(server).each do |template, conf_file|
        @server = server
        template_path = File.expand_path("templates/#{template}")
        host_config   = ERB.new(File.new(template_path).read).result(binding)
        upload! StringIO.new(host_config), "/tmp/#{conf_file}"
      end
    end

    def ensure_access_docker
      unless test("docker", "ps")
        execute "sudo", "usermod", "-a", "-G", "docker", "#{ENV["USER"]}"
        fatal "Newly added to docker group, this run will fail, next run will succeed. Simply try again."
      end
    end

    def restart_postgres(server)
      if exists?(server)
        if is_running?(server)
          execute("docker", "restart", server.container_name)
        else
          execute("docker", "start", server.container_name)
        end
      else
        publish = ""
        publish = "--publish 127.0.0.1:#{server.publish_port}:5432" if server.publish
        execute(
          "docker", "run",
          "--detach", "--tty",
          "--name", server.container_name,
          "--volume /#{server.domain}-#{server.container_name}-data:/postgres-data:rw",
          "#{publish}",
          server.cluster.image_name
        )
      end
    end

    def exists?(server)
      test "docker", "inspect", server.container_name
    end

    def is_running?(server)
      (capture "docker", "inspect",
        "--format='{{.State.Running}}'",
        server.container_name).strip == "true"
    end

    def ensure_role(server, role)
      unless test "echo", "\"SELECT", "*", "FROM", "pg_user", "WHERE", "usename", "=", "'#{role}';\"", "|",
        "docker", "run  ", "--rm", "--interactive", "--link",
        "#{server.container_name}:postgres", server.cluster.image_name,
        "bash", "-c", "'exec psql -h", "$POSTGRES_PORT_5432_TCP_ADDR",
        "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'", "|",
        "grep", "-q", role
        execute "echo", "\"CREATE", "ROLE", role,
          "WITH", "LOGIN", "ENCRYPTED", "PASSWORD", "'#{role}'", "CREATEDB;\"", "|",
          "docker", "run", "--rm ", "--interactive",
          "--link", "#{server.container_name}:postgres", server.cluster.image_name,
          "bash", "-c", "'exec", "psql", "-h", "$POSTGRES_PORT_5432_TCP_ADDR",
          "-p", "$POSTGRES_PORT_5432_TCP_PORT", "-U", "postgres'"
      end
    end
end
