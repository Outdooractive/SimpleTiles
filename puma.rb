require 'pp'
require 'json'

# Common variables
BASE_DIR   = File.dirname(__FILE__)
PID_DIR    = '/var/run/simple_tiles'
PID_FILE   = File.join(PID_DIR, 'puma.pid')
STATE_FILE = File.join(PID_DIR, 'puma.state')
CTL_FILE   = 'unix://' + File.join(PID_DIR, 'puma.ctl')
LOG_FILE   = '/var/log/simple_tiles/simple_tiles.error.log'

# Configuration for TCP port checks
config_file = '/etc/simple_tiles.cfg'

configuration = {
    port: 3000,
    hostname: '127.0.0.1'
}

begin
    configuration.merge!(JSON.parse(File.read(config_file), symbolize_names: true))
rescue Exception => e
    pp e
end

# Settings
directory BASE_DIR
rackup    File.join(BASE_DIR, 'config.ru')

environment 'production'
daemonize   true
threads     4, 32

pidfile    PID_FILE
state_path STATE_FILE
activate_control_app CTL_FILE

stdout_redirect LOG_FILE, LOG_FILE, true

bind "tcp://#{configuration[:hostname]}:#{configuration[:port]}"

on_restart do
  puts 'On restart...'
end
