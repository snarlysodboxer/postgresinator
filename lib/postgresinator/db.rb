namespace :pg do
  namespace :db do

    #desc "Idempotently setup one or more databases."
    task :setup => ['pg:ensure_setup'] do
      on roles(:db) do |host|
        fetch(:postgres_databases).each do |database|
          Rake::Task['pg:check:settings:database'].invoke(database[:name])
          Rake::Task['pg:check:settings:database'].reenable
          unless pg_role_exists?(database[:db_role])
            info "Creating role #{database[:db_role]} on #{host}"
            pg_create_role(database[:db_role], database[:pass])
          end
          unless pg_database_exists?(database[:name])
            info "Creating database #{database[:name]} on #{host}"
            pg_create_database(database)
            pg_grant_database(database)
          end
        end
      end
    end

    desc "Restore 'dump_file' in /tmp on the master server into 'database_name'."
    task :restore, [:dump_file, :database_name]  => ['pg:ensure_setup'] do |t, args|
      on roles(:db) do |host|
        if pg_database_empty?(args.database_name)
          clean = ""
        else
          pg_confirm_database_overwrite?(args.database_name) ? clean = "--clean" : exit(0)
        end
        pg_docker_restore_command(host, args, clean)
      end
    end

    desc "Dump 'database_name' into /tmp/'dump_file' on the master server."
    task :dump, [:dump_file, :database_name]  => ['pg:ensure_setup'] do |t, args|
      on roles(:db) do |host|
        if file_exists?("/tmp/#{args.dump_file}")
          exit unless(pg_confirm_file_overwrite?(args.dump_file))
        end
        pg_docker_dump_command(host, args)
      end
    end

    desc "Enter psql interactive mode on the master."
    task :interactive => 'pg:ensure_setup' do
      on roles(:db) do |host|
        system pg_docker_interactive_command(host)
      end
    end

    namespace :interactive do
      desc "Print the command to enter psql interactive mode on the master."
      task :print => 'pg:ensure_setup' do
        on roles(:db) do |host|
          info ["You can paste the following command into a terminal on #{host}",
            "to enter psql interactive mode for",
            "#{host.properties.postgres_container_name}:"].join(' ')
          info pg_docker_interactive_print_command(host)
        end
      end
    end

    desc "List the databases from the master."
    task :list => ['pg:ensure_setup'] do |t, args|
      on roles(:db) do
        pg_docker_list_databases_command(host)
      end
    end

    namespace :list do
      desc "List the roles from the master."
      task :roles => ['pg:ensure_setup'] do |t, args|
        on roles(:db) do
          pg_docker_list_roles_command(host)
        end
      end
    end

    desc "Show the streaming replication status of each instance."
    task :streaming => ['pg:ensure_setup'] do
      on roles(:db) do |host|
        info "Streaming status of #{host.properties.postgres_container_name} on #{host}:"
        pg_docker_streaming_master_command(host)
      end
      on roles(:db_slave, :in => :parallel) do
        info "Streaming status of #{host.properties.postgres_container_name} on #{host}:"
        pg_docker_streaming_slave_command(host)
      end
    end


    def pg_confirm_file_overwrite?(dump_file)
      warn "A file named #{dump_file} already exists on #{host} in /tmp. If you continue, you will overwrite it."
      ask :yes_or_no, "Are you positive?"
      case fetch(:yes_or_no).chomp.downcase
      when "yes"
        true
      when "no"
        false
      else
        warn "Please enter 'yes' or 'no'"
        pg_confirm_file_overwrite?(dump_file)
      end
    end

    def pg_confirm_database_overwrite?(database_name)
      warn "There is already data in the database '#{database_name}' on #{host} in the container " +
        "'#{host.properties.postgres_container_name}' which stores it's data in #{fetch(:postgres_data_path)} on the host."
      warn "If you continue, you must be positive you want to overwrite the existing data."
      ask :yes_or_no, "Are you positive?"
      case fetch(:yes_or_no).chomp.downcase
      when "yes"
        true
      when "no"
        false
      else
        warn "Please enter 'yes' or 'no'"
        pg_confirm_database_overwrite?(database_name)
      end
    end
  end
end
