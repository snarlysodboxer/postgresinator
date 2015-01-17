# config valid only for Capistrano 3.2.1
lock '3.2.1'

##### postgresinator
### ------------------------------------------------------------------
set :application,                   "my_app_name"
set :preexisting_ssh_user,          ENV['USER']
set :deployment_username,           "deployer"
set :webserver_username,            "www-data" # needed for intergration w/ deployinator
### ------------------------------------------------------------------
