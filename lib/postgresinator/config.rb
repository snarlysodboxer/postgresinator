namespace :config do
  desc 'Write example config files'
  task :write_examples do
    run_locally do
      execute "mkdir -p ./templates"

      # example postgresinator.rb
      config = File.read(File.dirname(__FILE__) + '/examples/postgresinator_example.rb')
      File.open('./postgresinator_example.rb', 'w') { |f| f.write(config) }
      info "Wrote './postgresinator_example.rb'"
      info "Run `mv postgresinator_example.rb postgrestinator.rb` or diff those files and add the needed lines."

      # example postgresql.conf.erb
      config = File.read(File.dirname(__FILE__) + '/examples/postgresql_example.conf.erb')
      File.open('./templates/postgresql_example.conf.erb', 'w') { |f| f.write(config) }
      info "Wrote './templates/postgres_example.conf.erb'"
      info "Run `mv templates/postgresql_example.conf.erb templates/postgresql.conf.erb` or diff those files and add the needed lines."

      # example pg_hba.conf.erb
      config = File.read(File.dirname(__FILE__) + '/examples/pg_hba_example.conf.erb')
      File.open('./templates/pg_hba_example.conf.erb', 'w') { |f| f.write(config) }
      info "Wrote './templates/pg_hba_example.conf.erb'"
      info "Run `mv templates/pg_hba_example.conf.erb templates/pg_hba.conf.erb` or diff those files and add the needed lines."

      # example recovery.conf.erb
      config = File.read(File.dirname(__FILE__) + '/examples/recovery_example.conf.erb')
      File.open('./templates/recovery_example.conf.erb', 'w') { |f| f.write(config) }
      info "Wrote './templates/recovery_example.conf.erb'"
      info "Run `mv templates/recovery_example.conf.erb templates/recovery.conf.erb` or diff those files and add the needed lines."
    end
  end
end
