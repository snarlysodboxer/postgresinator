postgresinator
============

*Opinionatedly Deploy PostgreSQL instances, setting up streaming replication to one or more slaves.*

This library uses Rake and SSHKit, and relies on SSH access with passwordless sudo rights, as well as Docker installed on the hosts.

Currently only tested against PostgreSQL 9.1, but should work just as well for newer versions.

### Installation:
* `gem install postgresinator` (Or add it to your Gemfile and `bundle install`.)
* Create a Rakefile which requires postgresinator:
`echo "require 'postgresinator'" > Rakefile`
* Create example configs:
`rake pg:write_example_configs`
* Turn them into real configs by removing the `_example` portions of their names, and adjusting their content to fit your needs. (Later when you upgrade to a newer version of postgresinator, you can `pg:write_example_configs` again and diff your current configs against the new configs.)
* You most likely won't need to adjust the content of the ERB templates, but you can to add any custom PostgreSQL settings you need.
* You can later update a template (PostgreSQL config) file and run `rake pg:setup` again to update the config files on each instance and restart them.

### Usage:
`rake -T` will help remind you of the available commands, see this for more details.
* After setting up your `postgresinator.rb` config file, simply run:
`rake pg:setup`
* Run `rake pg:setup` again to see it find everything is already setup, and do nothing.
* Run `rake pg:statuses` to see the statuses of each instance. (Note: it usually takes a couple of minutes to start seeing the streaming activity.)
* Run `rake pg:restore['dump_file','database_name']` to pg_restore a .tar file into the instances.
* Run `rake pg:dump['dump_file','database_name']` to pg_dump a .tar file.
* Run `rake pg:print_interactive['domain']` to print the command to enter psql interactive mode on one of the instances.

###### TODOs:
* Make `pg:statuses` more readable and useful.
* Make the recovery.conf dependancy more logically defined and adaptable.
