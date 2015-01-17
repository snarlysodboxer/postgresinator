##### postgresinator
### ------------------------------------------------------------------
set :domain,                        "my-app.example.com"
server fetch(:domain),
  :user                             => fetch(:deployment_username),
  :roles                            => ["app", "web", "db"],
  :postgres_port                    => "5432"
server 'my-app-db-slave.example.com',
  :user                             => fetch(:deployment_username),
  :roles                            => ["db_slave"],
  :no_release                       => true,
  :postgres_port                    => "5433"
server 'my-app-db-slave2.example.com',
  :user                             => fetch(:deployment_username),
  :roles                            => ["db_slave"],
  :no_release                       => true,
  :postgres_port                    => "5433"
  # only for override, let postgresinator setup postgres_container_name
  #:postgres_container_name => "my_custom_name"
set :postgres_image_name,           "snarlysodboxer/postgresql:0.0.1"
set :postgres_replicator_pass,      "yourpassword"
set :postgres_databases,            [
  {
    :name                             => "name",
    :db_role                          => "role",
    :pass                             => "pass"
  }
]
### ------------------------------------------------------------------
