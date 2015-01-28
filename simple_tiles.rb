#!/usr/bin/env ruby
# encoding: UTF-8

require 'thin'
require 'rack'

require 'pp'
require 'logger'
require 'socket'

require 'pg'
require 'mongo'
require 'sqlite3'
require 'json'

$stdout.sync = true

#
# projects and global statistics counter
#

$mbtiles_projects = {}

$app_request_counter = 0
$app_success_counter = 0
$app_fail_counter = 0


#
# Tools
#
class ::Logger; alias_method :write, :<<; end

module Math

    def self.pow(x, y)
        x ** y
    end

end


#
# Logger
#
module Rack

    class SimpleTilesLogger
        FORMAT         = "[%s] %s %s %s %s - %.0f ms\n".freeze
        PATH_INFO      = 'PATH_INFO'.freeze
        CONTENT_LENGTH = 'Content-Length'.freeze
        REQUEST_METHOD = 'REQUEST_METHOD'.freeze

        def initialize(app, logger=nil)
            @app = app
            @logger = logger
        end

        def call(env)
            began_at = Time.now
            status, header, body = @app.call(env)
            header = Utils::HeaderHash.new(header)
            body = BodyProxy.new(body) { log(env, status, header, began_at) }
            [status, header, body]
        end

        private

        def log(env, status, header, began_at)
            ended_at = Time.now

            content_length = extract_content_length(header)

            msg = FORMAT % [
                ended_at.strftime("%d/%b/%Y:%H:%M:%S %z"),
                env[REQUEST_METHOD],
                env[PATH_INFO],
                status.to_s[0..3],
                content_length.to_s,
                (ended_at - began_at) * 1000.0 ]

            logger = @logger || env['rack.errors']

            if logger.respond_to?(:write)
                logger.write(msg)
            else
                logger << msg
            end
        end

        def extract_content_length(headers)
            value = headers[CONTENT_LENGTH] or return '-'
            value.to_s == '0' ? '-' : value
        end
    end

end


#
# Controller
#
class SimpleTilesAdapter
    include Rack::Mime
    include Mongo

    CONTENT_TYPE = 'Content-Type'.freeze

    # Setup
    def SimpleTilesAdapter.setup_db(config)
        layers = config[:layers]

        layers.each do |layer|
            current_name = layer[:name]
            current_files = layer[:files]

            if current_name.nil? or current_files.nil? or current_files.length == 0 then
                puts "Error loading project '#{current_name}', continuing..."
                next
            end

            $mbtiles_projects[current_name] = {}
            $mbtiles_projects[current_name][:database] = {}
            $mbtiles_projects[current_name][:format] = {}
            $mbtiles_projects[current_name][:db_type] = {}

            $mbtiles_projects[current_name][:request_counter] = 0
            $mbtiles_projects[current_name][:success_counter] = 0
            $mbtiles_projects[current_name][:fail_counter] = 0

            current_files.each do |current_tileset|
                SimpleTilesAdapter.open_database(current_name, current_tileset)
            end
        end
    end

    def SimpleTilesAdapter.open_database(current_name, current_tileset)
        filename = current_tileset[:filename]
        return if filename.nil?

        if current_tileset[:default_tile_path] then
            $mbtiles_projects[current_name][:default_tile] = File.read(current_tileset[:default_tile_path])
        end

        zoom_range = current_tileset[:zoom_range]
        zoom_range = [0..18] if zoom_range.nil? or zoom_range.length == 0

        if filename.include? "driver=postgres" then
            SimpleTilesAdapter.open_postgres($mbtiles_projects[current_name], current_name, filename, zoom_range)
        elsif filename.include? "driver=mongodb" then
            SimpleTilesAdapter.open_mongodb($mbtiles_projects[current_name], current_name, filename, zoom_range)
        else
            SimpleTilesAdapter.open_sqlite($mbtiles_projects[current_name], current_name, filename, zoom_range)
        end
    end

    # MongoDB
    def SimpleTilesAdapter.open_mongodb(project, current_name, filename, zoom_range)
        options = {
            'host' => '127.0.0.1',
            'port' => 27017
        }
        options.merge! Hash[filename.split(" ").map {|value| value.split("=")}]

        client = MongoClient.new(options['host'], options['port'], :slave_ok => true)
        db = client.db("admin")
        if db.nil? then
            puts "Error opening database at '#{filename}'"
            exit(1)
        end

        if options['user'] and options['password'] and not db.authenticate(options['user'], options['password']) then
            puts "Error opening database at '#{filename}'"
            exit(1)
        end

        db = client.db(options['dbname'])
        coll = db["tiles"]

        zoom_range.each do |current_zoom|
            project[:database][current_zoom] = coll
            project[:db_type][current_zoom] = 'mongodb'
        end

        image_format = db["metadata"].find_one({"name" => "format"})['value'] rescue nil

        if image_format then
            zoom_range.each {|current_zoom| project[:format][current_zoom] = image_format}
        else
            puts "- Missing format metadata in the '#{current_name}' layer' #{zoom_range}, assuming 'png'..."
            zoom_range.each {|current_zoom| project[:format][current_zoom] = 'png'}
        end

        puts "- Layer '#{current_name}' #{zoom_range} (mongodb://#{options['host']}:#{options['port']}/#{options['dbname']}) uses '#{project[:format][zoom_range[0]]}' image tiles"
    end

    # SQLite
    def SimpleTilesAdapter.open_sqlite(project, current_name, filename, zoom_range)
        filename = File.expand_path(File.join(File.dirname(__FILE__), filename)) if filename[0] != '/'

        db = SQLite3::Database.new(filename)

        if db.nil? then
            puts "Error opening database at '#{filename}'"
            exit(1)
        end

        zoom_range.each do |current_zoom|
            project[:database][current_zoom] = db
            project[:db_type][current_zoom] = 'sqlite'
        end

        db.execute "PRAGMA cache_size = 20000"
        db.execute "PRAGMA temp_store = memory"

        image_format = db.get_first_row("SELECT value FROM metadata WHERE name='format'")['value'] rescue nil

        if image_format then
            zoom_range.each {|current_zoom| project[:format][current_zoom] = image_format}
        else
            puts "- Missing format metadata in the '#{current_name}' layer' #{zoom_range}, assuming 'png'..."
            zoom_range.each {|current_zoom| project[:format][current_zoom] = 'png'}
        end

        puts "- Layer '#{current_name}' #{zoom_range} (#{filename}) uses '#{project[:format][zoom_range[0]]}' image tiles"
    end

    # PostgreSQL
    def SimpleTilesAdapter.open_postgres(project, current_name, filename, zoom_range)
        options = {
            'host' => '127.0.0.1',
            'port' => 5432
        }
        options.merge! Hash[filename.split(" ").map {|value| value.split("=")}]
        options.delete('driver')

        db = PG::Connection.open(options)

        if db.nil? then
            puts "Error opening database at '#{filename}'"
            exit(1)
        end

        zoom_range.each do |current_zoom|
            project[:database][current_zoom] = db
            project[:db_type][current_zoom] = 'pg'
        end

        image_format = db.exec("SELECT value FROM metadata WHERE name='format'").getvalue(0,0) rescue nil

        if image_format then
            zoom_range.each {|current_zoom| project[:format][current_zoom] = image_format}
        else
            puts "- Missing format metadata in the '#{current_name}' layer' #{zoom_range}, assuming 'png'..."
            zoom_range.each {|current_zoom| project[:format][current_zoom] = 'png'}
        end

        puts "- Layer '#{current_name}' #{zoom_range} (pg://#{options['host']}:#{options['port']}/#{options['dbname']}) uses '#{project[:format][zoom_range[0]]}' image tiles"
    end


    # Request handling
    def call(env)
        req = Rack::Request.new(env)
        res = Rack::Response.new

        $app_request_counter += 1

        match = /^\/(?<project>\w+)\/(?<zoom>\d+)\/(?<x>\d+)\/(?<y>\d+)\.(?<format>\w+)$/.match(req.path_info) rescue nil

        if match.nil? then
            $app_fail_counter += 1

            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        project_name = match[:project]
        image_format = match[:format]

        zoom = Integer(match[:zoom])
        x    = Integer(match[:x])
        y    = Integer(match[:y])

        # Flip the y coordinate
        y = Math.pow(2, zoom) - 1 - y

        project = $mbtiles_projects[project_name]
        project[:request_counter] += 1 if project

        if project.nil? or zoom < 0 or x < 0 or y < 0 then
            $app_fail_counter += 1
            project[:fail_counter] += 1 if project

            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        # puts "project=#{project_name}, z=#{zoom}, x=#{x}, y=#{y}, format=#{image_format}"

        tile_data = nil

        db        = project[:database][zoom] rescue nil
        db_format = project[:format][zoom] rescue nil

        if db and db_format == image_format then
            db_type = project[:db_type][zoom]

            if db_type == 'sqlite' then
                tile_data = db.get_first_row("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", zoom, x, y)[0] rescue nil

            elsif db_type == 'mongodb' then
                tile_id = "%d/%d/%d/%d" % [zoom, x, y, 1]
                tile_data = db.find_one({"_id" => tile_id})['d'] rescue nil

            elsif db_type == 'pg' then
                tile_data = db.exec_params('SELECT tile_data FROM tiles WHERE zoom_level=$1 AND tile_column=$2 AND tile_row=$3 AND tile_scale=1', [zoom, x, y], 1).getvalue(0,0) rescue nil

                if tile_data.nil? then
                    tile_data = db.exec_params('SELECT tile_data FROM tiles WHERE zoom_level=$1 AND tile_column=$2 AND tile_row=$3', [zoom, x, y], 1).getvalue(0,0) rescue nil
                end
            end
        end

        if tile_data.nil? then
            tile_data = project[:default_tile]
            image_format = "png"
        end

        if tile_data.nil? then
            $app_fail_counter += 1
            project[:fail_counter] += 1

            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        $app_success_counter += 1
        project[:success_counter] += 1

        res.headers[CONTENT_TYPE] = mime_type(image_format) if ENV["RACK_ENV"] == 'production'
        res.write tile_data
 
        # returns the standard [status, headers, body] array
        res.finish
    end

end

#
# Statistics controller
#
class StatisticsAdapter

    def call(env)
        req = Rack::Request.new(env)
        res = Rack::Response.new

        # Only localhost allowed
        local_ips = Socket.ip_address_list.map {|address| address.ip_address}
        if not local_ips.include? req.ip then
            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        match = /^\/(?<option_name>\w+)/.match(req.path_info) rescue nil

        option_name = match[:option_name] rescue nil

        if option_name == 'config' then
            res.write "graph_title Simpletiles request rate\n"
            res.write "graph_vlabel requests/s\n"
            res.write "graph_category simpletiles\n"

            res.write "requests.label requests\n"
            res.write "requests.type DERIVE\n"
            res.write "requests.min 0\n"
            res.write "success.label success\n"
            res.write "success.type DERIVE\n"
            res.write "success.min 0\n"
            res.write "fail.label fail\n"
            res.write "fail.type DERIVE\n"
            res.write "fail.min 0\n"

            $mbtiles_projects.each_key do |project_name|
                res.write "#{project_name}_requests.label requests\n"
                res.write "#{project_name}_requests.type DERIVE\n"
                res.write "#{project_name}_requests.min 0\n"
                res.write "#{project_name}_success.label success\n"
                res.write "#{project_name}_success.type DERIVE\n"
                res.write "#{project_name}_success.min 0\n"
                res.write "#{project_name}_fail.label fail\n"
                res.write "#{project_name}_fail.type DERIVE\n"
                res.write "#{project_name}_fail.min 0\n"
            end

            return res.finish
        end

        res.write "requests.value #{$app_request_counter}\nsuccess.value #{$app_success_counter}\nfail.value #{$app_fail_counter}\n"

        $mbtiles_projects.each do |project_name, project|
            res.write "#{project_name}_requests.value #{project[:request_counter]}\n#{project_name}_success.value #{project[:success_counter]}\n#{project_name}_fail.value #{project[:fail_counter]}\n"
        end

        # returns the standard [status, headers, body] array
        res.finish
    end

end


#
# Startup
#
environment = ENV["RACK_ENV"] || 'development'
config_file = if environment == 'development' then 'simple_tiles.cfg' else '/etc/simple_tiles.cfg' end

configuration = {
    port: 3000,
    hostname: '127.0.0.1',
    logfile: 'console',
    path_prefix: '',
    layers: []
}

begin
    configuration.merge!(JSON.parse(File.read(config_file), :symbolize_names => true))
rescue Exception => e
    puts "Invalid configuration file #{config_file}"
    exit(1)
end

puts "SimpleTiles server listening on #{configuration[:hostname]}:#{configuration[:port]} in #{environment} mode, log to #{configuration[:logfile]}"

app_logger = STDOUT

if configuration[:logfile] != 'console' then
    puts "Redefining app_logger..."
    app_logger = Logger.new(File.expand_path(configuration[:logfile]), 'daily')
end

SimpleTilesAdapter.setup_db(configuration)

Thin::Server.start(configuration[:hostname], configuration[:port]) do
    use Rack::SimpleTilesLogger, app_logger

    map configuration[:path_prefix] do
        run SimpleTilesAdapter.new
    end

    map '/statistics' do
        run StatisticsAdapter.new
    end

end


