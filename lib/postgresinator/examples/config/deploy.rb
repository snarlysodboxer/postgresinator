# config valid only for Capistrano 3.1
lock '3.2.1'

set :application,                   "my_app_name"
set :deployment_username,           "deployer"
set :webserver_username,            "www-data" # this is needed for intergration w/ deployinator
set :preexisting_ssh_user,          ENV['USER']
