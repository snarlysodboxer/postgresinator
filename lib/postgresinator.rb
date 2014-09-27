# This library relies on
#   SSH access with passwordless sudo rights and
#   docker installed on the host

require 'rake'
require 'sshkit'
require 'sshkit/dsl'

load 'postgresinator/pg.rb'
load 'postgresinator/config.rb'
