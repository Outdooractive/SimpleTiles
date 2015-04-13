#\ -s puma
# encoding: UTF-8

require 'pp'
require 'json'
require 'logger'
require 'rack'

$:.unshift File.dirname(__FILE__)
require 'simple_tiles'

$stdout.sync = true

#
# Startup
#
environment = ENV['RACK_ENV'] || 'development'
config_file = if environment == 'development' then File.join(Dir.pwd, 'simple_tiles.cfg') else '/etc/simple_tiles.cfg' end
layer_config_file = if environment == 'development' then File.join(Dir.pwd, 'simple_tiles_layers.cfg') else '/etc/simple_tiles_layers.cfg' end

configuration = {
    port: 3000,
    hostname: '127.0.0.1',
    logfile: 'console',
    path_prefix: ''
}

layer_configuration = {
    layers: []
}

begin
    configuration.merge!(JSON.parse(File.read(config_file), symbolize_names: true))
rescue Exception => e
    pp e
    puts "Invalid configuration file #{config_file}"
    exit(1)
end

begin
    layer_configuration.merge!(JSON.parse(File.read(layer_config_file), symbolize_names: true))
rescue Exception => e
    pp e
    puts "Invalid layer configuration file #{config_file}"
    exit(1)
end

puts "[#{Time.now.strftime('%d/%b/%Y:%H:%M:%S %z')}] SimpleTiles server listening on #{configuration[:hostname]}:#{configuration[:port]} in #{environment} mode, log to #{configuration[:logfile]}"

app_logger = nil

if configuration[:logfile] == 'null' or configuration[:logfile] == '/dev/null'
    puts "[#{Time.now.strftime('%d/%b/%Y:%H:%M:%S %z')}] Discarding access logs"
    app_logger = Logger.new('/dev/null')
elsif configuration[:logfile] == 'console'
    puts "[#{Time.now.strftime('%d/%b/%Y:%H:%M:%S %z')}] Logging to STDOUT"
    app_logger = STDOUT
else
    puts "[#{Time.now.strftime('%d/%b/%Y:%H:%M:%S %z')}] Redefining app_logger..."
    app_logger = Logger.new(File.expand_path(configuration[:logfile]), 'daily')
end

SimpleTilesAdapter.setup_db(layer_configuration)

use Rack::SimpleTilesLogger, app_logger if app_logger

puts "[#{Time.now.strftime('%d/%b/%Y:%H:%M:%S %z')}] Setup done, loading maps..."

map configuration[:path_prefix] do
    run SimpleTilesAdapter.new
end

map '/statistics' do
    run StatisticsAdapter.new
end

map '/statistics.json' do
    run JSONStatisticsAdapter.new
end
