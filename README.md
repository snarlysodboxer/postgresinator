postgresinator
============

*Opinionatedly Deploy PostgreSQL instances, setting up streaming replication to one or more slaves.*

This library is a Capistrano 3.x plugin, and relies on SSH access with passwordless sudo rights, as well as Docker installed on the hosts.

`postgresinator` aims to not clober over anything, however if you use multiple <stage>.rb configs referencing the same domains, you need to manually verify they are not attempting to setup more than one instance on the same port for a paricular domain (host).

PostgreSQL only does streaming replication of an entire instance to an entire instance; all databases per instance are streamed to the slave(s).

Currently only tested against PostgreSQL 9.1, but should work just as well for newer versions.

### Installation:
* `gem install postgresinator` (Or add it to your Gemfile and `bundle install`.)
* Create a Capfile which requires postgresinator:
`echo "require 'postgresinator'" > Capfile`
* Create example configs:
`cap staging pg:write_example_configs`
* Turn them into real configs by removing the `_example` portions of their names, and adjusting their content to fit your needs. (Later when you upgrade to a newer version of postgresinator, you can `pg:write_example_configs` again and diff your current configs against the new configs.)
* You can add any custom PostgreSQL setting you need by adjusting the content of the ERB templates. You won't need to change them to get started.
* You can later update a template (PostgreSQL config) and run `cap <stage> pg:setup` again to update the config files on each instance and restart them.
* You may want to for example override entrypoints for use with a custom built docker image, or to tune SQL commands. To view the list of overridable settings which you can copy-paste into your own deploy.rb or <stage>.rb, check the built-in.rb by running:
`cap <stage> postgresinator:write_built_in`

*NOTE: Rake does not take arguments with spaces between them, they have to be in the exact form:*
`cap <stage> pg:<command>['arg1,'arg2']`

### Usage:
`rake -T` will help remind you of the available commands, see this for more details.
* After setting up your `postgresinator.rb` config file, simply run:
`cap <stage> pg:setup`
* Run `cap <stage> pg:setup` again to see it find everything is already setup, and do nothing.
* Run `cap <stage> pg:status` to see the statuses of each instance.
* Run `cap <stage> pg:db:list` to list the databases from the master.
* Run `cap <stage> pg:db:list:roles` to list the database roles from the master.
* Run `cap <stage> pg:db:streaming` to see the streaming statuses of each instance. (Note: it usually takes a couple of minutes to start seeing the streaming activity.)
* Run `cap <stage> pg:db:restore['dump_file','database_name']` to pg_restore a .tar file into the instances.
* Run `cap <stage> pg:db:dump['dump_file','database_name']` to pg_dump a .tar file.
* Run `cap <stage> pg:db:interactive` to enter psql interactive mode on the master.
* Run `cap <stage> pg:db:interactive:print` to print the command to run on the server to enter psql interactive mode on the master.

###### TODOs:
* More thoroughly test recovery from failure of the master; create task(s) for promoting a new master.

###### Debugging:
* You can add the `--trace` option at the end of any rake task to see when which task is invoked, and when which task is actually executed.
* If you want to put on your DevOps hat, you can run `cap -T -A` to see each individually available task, and run them one at a time to debug each one.
