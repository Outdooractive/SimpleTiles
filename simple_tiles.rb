# encoding: UTF-8

require 'rack'

require 'pp'
require 'logger'
require 'socket'

require 'json'
require 'mongo'

if RUBY_PLATFORM != 'java'
    require 'pg'
    require 'sqlite3'
end

$stdout.sync = true

#
# Tools
#
class ::Logger; alias_method :write, :<<; end

module Math

    def self.pow(x, y)
        x**y
    end

end

# http://www.johndcook.com/blog/skewness_kurtosis/
class RequestStatistics

    def initialize
        clear
    end

    def clear
        @n = 0
        @m1 = @m2 = @m3 = @m4 = 0.0
    end

    def push(x)
        n1 = @n
        @n += 1

        delta = x - @m1
        delta_n = delta / @n
        delta_n2 = delta_n * delta_n
        term1 = delta * delta_n * n1

        @m1 += delta_n
        @m4 += term1 * delta_n2 * ((@n * @n) - (3 * @n) + 3) + 6 * delta_n2 * @m2 - 4 * delta_n * @m3
        @m3 += term1 * delta_n * (@n - 2) - 3 * delta_n * @m2
        @m2 += term1
    end

    def num_samples
        @n
    end

    def mean
        @m1
    end

    def variance
        @m2 / (@n - 1.0)
    end

    def standard_deviation
        Math.sqrt(variance)
    end

    def skewness
        Math.sqrt(@n) * @m3 / Math.pow(@m2, 1.5)
    end

    def kurtosis
        (@n * @m4) / (@m2 * @m2) - 3.0
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
        X_PROJECT_NAME = 'X-PROJECT-NAME'.freeze

        def initialize(app, logger = nil)
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
            request_time_ms = (ended_at - began_at) * 1000.0

            content_length = extract_content_length(header)

            msg = FORMAT % [ ended_at.strftime('%d/%b/%Y:%H:%M:%S %z'),
                             env[REQUEST_METHOD],
                             env[PATH_INFO],
                             status.to_s[0..3],
                             content_length.to_s,
                             request_time_ms
                           ]

            logger = @logger || env['rack.errors']

            if logger.respond_to?(:write)
                logger.write(msg)
            else
                logger << msg
            end

            if status.to_s[0..3] == '200'
                project_name = header[X_PROJECT_NAME]

                if project_name
                    request_statistics = ($mbtiles_counters[project_name][:request_statistics] ||= RequestStatistics.new)
                    request_statistics.push(request_time_ms)
                end

                $app_request_statistics.push(request_time_ms)
            end
        end

        def extract_content_length(headers)
            value = headers[CONTENT_LENGTH] or return '-'
            value.to_s == '0' ? '-' : value
        end
    end

end

#
# projects and global statistics counter
#

$server_start_time = Time.now.to_i

$mbtiles_projects = {}
$project_aliases  = {}
$mbtiles_counters = {}

$app_request_counter = 0
$app_success_counter = 0
$app_fail_counter    = 0

$app_request_statistics = RequestStatistics.new

#
# Controller
#
class SimpleTilesAdapter
    include Rack::Mime
    include Mongo

    CONTENT_TYPE   = 'Content-Type'.freeze
    X_PROJECT_NAME = 'X-PROJECT-NAME'.freeze

    # Setup
    def SimpleTilesAdapter.setup_db(config)
        layers = config[:layers]

        layers.each do |layer|
            project_name  = layer[:name]
            alias_name    = layer[:alias]
            current_files = layer[:files]

            if project_name.nil? or current_files.nil? or current_files.length == 0
                puts "Error loading project '#{project_name}', continuing..."
                next
            end

            $mbtiles_projects[project_name] = {}
            $mbtiles_projects[project_name][:database] = {}
            $mbtiles_projects[project_name][:format] = {}
            $mbtiles_projects[project_name][:db_type] = {}

            counters = {
                requests: 0,
                success: 0,
                fail: 0
            }
            $mbtiles_counters[project_name] = counters

            current_files.each do |current_tileset|
                SimpleTilesAdapter.open_database(project_name, current_tileset)
            end

            unless alias_name.nil? or alias_name.length == 0
                if $project_aliases.key?(alias_name)
                    puts "Alias #{alias_name} (-> #{project_name} already exists, skipping..."
                    next
                end

                $project_aliases[alias_name] = project_name

                # Alias and Original point to the same object
                $mbtiles_projects[alias_name] = $mbtiles_projects[project_name]
                $mbtiles_counters[alias_name] = $mbtiles_counters[project_name]
            end
        end
    end

    def SimpleTilesAdapter.open_database(current_name, current_tileset)
        filename = current_tileset[:filename]
        return if filename.nil?

        if current_tileset[:default_tile_path]
            $mbtiles_projects[current_name][:default_tile] = File.read(current_tileset[:default_tile_path])
        end

        zoom_range = current_tileset[:zoom_range]
        zoom_range = [0..18] if zoom_range.nil? or zoom_range.length == 0

        begin
            if filename.include? 'driver=postgres'
                SimpleTilesAdapter.open_postgres($mbtiles_projects[current_name], current_name, filename, zoom_range)
            elsif filename.include? 'driver=mongodb'
                SimpleTilesAdapter.open_mongodb($mbtiles_projects[current_name], current_name, filename, zoom_range)
            else
                SimpleTilesAdapter.open_sqlite($mbtiles_projects[current_name], current_name, filename, zoom_range)
            end
        rescue Exception => e
            puts "[#{Time.now.strftime('%d/%b/%Y:%H:%M:%S %z')}] Database #{current_name} not yet ready, waiting..."
            pp e
            sleep(5)
            retry
        end
    end

    # MongoDB
    def SimpleTilesAdapter.open_mongodb(project, current_name, filename, zoom_range)
        options = {
            'host' => '127.0.0.1',
            'port' => 27017
        }
        options.merge! Hash[filename.split(' ').map { |value| value.split('=') }]

        user_string = ''
        user_string = "#{options['user']}:#{options['password']}@" if options['user'] and options['password']
        connect_string = "mongodb://#{user_string}#{options['host']}:#{options['port']}/admin"

        client = MongoClient.from_uri(connect_string, slave_ok: true, pool_size: 10, op_timeout: 30)
        db = client.db(options['dbname'])
        if db.nil?
            puts "Error opening database at '#{filename}'"
            exit(1)
        end

        coll = db['tiles']

        zoom_range.each do |current_zoom|
            project[:database][current_zoom] = coll
            project[:db_type][current_zoom] = 'mongodb'
        end

        image_format = db['metadata'].find_one({'name' => 'format'})['value'] rescue nil

        if image_format
            zoom_range.each { |current_zoom| project[:format][current_zoom] = image_format }
        else
            puts "- Missing format metadata in the '#{current_name}' layer' #{zoom_range}, assuming 'png'..."
            zoom_range.each { |current_zoom| project[:format][current_zoom] = 'png' }
        end

        puts "- Layer '#{current_name}' #{zoom_range} (mongodb://#{options['host']}:#{options['port']}/#{options['dbname']}) uses '#{project[:format][zoom_range[0]]}' image tiles"
    end

    # SQLite
    if RUBY_PLATFORM == 'java'
        def SimpleTilesAdapter.open_sqlite(_project, _current_name, _filename, _zoom_range)
            puts "- WARNING: Skipping SQLite3 database '#{current_name}' on JRuby"
        end
    else
        def SimpleTilesAdapter.open_sqlite(project, current_name, filename, zoom_range)
            filename = File.expand_path(File.join(File.dirname(__FILE__), filename)) if filename[0] != '/'

            db = SQLite3::Database.new(filename)

            if db.nil?
                puts "Error opening database at '#{filename}'"
                exit(1)
            end

            zoom_range.each do |current_zoom|
                project[:database][current_zoom] = db
                project[:db_type][current_zoom] = 'sqlite'
            end

            db.execute 'PRAGMA cache_size = 20000'
            db.execute 'PRAGMA temp_store = memory'

            image_format = db.get_first_row("SELECT value FROM metadata WHERE name='format'")['value'] rescue nil

            if image_format
                zoom_range.each { |current_zoom| project[:format][current_zoom] = image_format }
            else
                puts "- Missing format metadata in the '#{current_name}' layer' #{zoom_range}, assuming 'png'..."
                zoom_range.each { |current_zoom| project[:format][current_zoom] = 'png' }
            end

            puts "- Layer '#{current_name}' #{zoom_range} (#{filename}) uses '#{project[:format][zoom_range[0]]}' image tiles"
        end
    end

    # PostgreSQL
    if RUBY_PLATFORM == 'java'
        def SimpleTilesAdapter.open_postgres(_project, _current_name, _filename, _zoom_range)
            puts "- WARNING: Skipping PostgreSQL database '#{current_name}' on JRuby"
        end
    else
        def SimpleTilesAdapter.open_postgres(project, current_name, filename, zoom_range)
            options = {
                'host' => '127.0.0.1',
                'port' => 5432
            }
            options.merge! Hash[filename.split(' ').map { |value| value.split('=') }]
            options.delete('driver')

            db = PG::Connection.open(options)

            if db.nil?
                puts "Error opening database at '#{filename}'"
                exit(1)
            end

            zoom_range.each do |current_zoom|
                project[:database][current_zoom] = db
                project[:db_type][current_zoom] = 'pg'
            end

            image_format = db.exec("SELECT value FROM metadata WHERE name='format'").getvalue(0, 0) rescue nil

            if image_format
                zoom_range.each { |current_zoom| project[:format][current_zoom] = image_format }
            else
                puts "- Missing format metadata in the '#{current_name}' layer' #{zoom_range}, assuming 'png'..."
                zoom_range.each { |current_zoom| project[:format][current_zoom] = 'png' }
            end

            puts "- Layer '#{current_name}' #{zoom_range} (pg://#{options['host']}:#{options['port']}/#{options['dbname']}) uses '#{project[:format][zoom_range[0]]}' image tiles"
        end
    end

    # Request handling
    def call(env)
        req = Rack::Request.new(env)
        res = Rack::Response.new

        $app_request_counter += 1

        match = /^\/(?<project>[\w\.]+)\/(?<zoom>\d+)\/(?<x>\d+)\/(?<y>\d+)\.(?<format>\w+)$/.match(req.path_info) rescue nil

        if match.nil?
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

        if project
            $mbtiles_counters[project_name][:requests] += 1
            res.header[X_PROJECT_NAME] = project_name
        end

        if project.nil? or zoom < 0 or x < 0 or y < 0
            $app_fail_counter += 1
            $mbtiles_counters[project_name][:fail] += 1 if project

            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        # puts "project=#{project_name}, z=#{zoom}, x=#{x}, y=#{y}, format=#{image_format}"

        tile_data = nil

        db        = project[:database][zoom] rescue nil
        db_format = project[:format][zoom] rescue nil
        db_error  = false

        if db and db_format == image_format
            db_type = project[:db_type][zoom]

            begin
                if db_type == 'sqlite'
                    tile_data = db.get_first_row('SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?', zoom, x, y)[0] rescue nil

                elsif db_type == 'mongodb'
                    tile_id = '%d/%d/%d/%d' % [zoom, x, y, 1]
                    db_result = db.find_one({'_id' => tile_id})
                    tile_data = db_result['d'] if db_result

                elsif db_type == 'pg'
                    tile_data = db.exec_params('SELECT tile_data FROM tiles WHERE zoom_level=$1 AND tile_column=$2 AND tile_row=$3 AND tile_scale=1', [zoom, x, y], 1).getvalue(0, 0) rescue nil

                    if tile_data.nil?
                        tile_data = db.exec_params('SELECT tile_data FROM tiles WHERE zoom_level=$1 AND tile_column=$2 AND tile_row=$3', [zoom, x, y], 1).getvalue(0, 0) rescue nil
                    end
                end
            rescue
                db_error = true
            end
        end

        if tile_data.nil? && !db_error
            tile_data = project[:default_tile]
            image_format = 'png'
        end

        if tile_data.nil?
            $app_fail_counter += 1
            $mbtiles_counters[project_name][:fail] += 1

            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        $app_success_counter += 1
        $mbtiles_counters[project_name][:success] += 1

        average_size = $mbtiles_counters[project_name][:average_size] || tile_data.length
        $mbtiles_counters[project_name][:average_size] = (average_size + tile_data.length) / 2

        res.headers[CONTENT_TYPE] = mime_type('.' + image_format)
        res.write tile_data

        # returns the standard [status, headers, body] array
        res.finish
    end

end

#
# Statistics controller
#
class JSONStatisticsAdapter

    def check_nan(number)
        number.nan? ? 0.0 : number
    end

    def call(env)
        req = Rack::Request.new(env)
        res = Rack::Response.new

        # Only localhost allowed
        local_ips = Socket.ip_address_list.map(&:ip_address)
        if not local_ips.include? req.ip
            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        stats = {
            'host' => Socket.gethostname,
            'uptime' => (Time.now.to_i - $server_start_time),
            'requests' => {
                'requests' => $app_request_counter,
                'success' => $app_success_counter,
                'fail' => $app_fail_counter
            },
            'request_time' => {
                'mean' => check_nan($app_request_statistics.mean),
                'stddev' => check_nan($app_request_statistics.standard_deviation),
                'skewness' => check_nan($app_request_statistics.skewness)
            },
            'projects' => {}
        }

        $mbtiles_counters.each do |project_name, counters|
            next if $project_aliases.key?(project_name)

            stats['projects'][project_name] = {}

            stats['projects'][project_name]['requests'] = {
                'requests' => counters[:requests],
                'success' => counters[:success],
                'fail' => counters[:fail]
            }

            request_statistics = counters[:request_statistics] || RequestStatistics.new

            stats['projects'][project_name]['request_time'] = {
                'mean' => check_nan(request_statistics.mean),
                'stddev' => check_nan(request_statistics.standard_deviation),
                'skewness' => check_nan(request_statistics.skewness)
            }
        end

        res.write stats.to_json

        # returns the standard [status, headers, body] array
        res.finish
    end

end

class StatisticsAdapter

    def call(env)
        req = Rack::Request.new(env)
        res = Rack::Response.new

        # Only localhost allowed
        local_ips = Socket.ip_address_list.map(&:ip_address)
        if not local_ips.include? req.ip
            res.status = 404
            res.write "Not Found: #{req.script_name}#{req.path_info}"
            return res.finish
        end

        match = /^\/(?<option_name>\w+)/.match(req.path_info) rescue nil

        option_name = match[:option_name] rescue nil

        if option_name == 'average_size'
            $mbtiles_counters.each do |project_name, counters|
                next if $project_aliases.key?(project_name)

                res.write "#{project_name}_average_size.value #{counters[:average_size]}\n"
            end

            return res.finish
        end

        if option_name == 'config'
            res.write "multigraph simpletiles_requests\n"
            res.write "graph_title Simpletiles request rate\n"
            res.write "graph_vlabel requests/s\n"
            res.write "graph_category simpletiles_requests\n"
            res.write "requests.label requests\n"
            res.write "requests.type DERIVE\n"
            res.write "requests.min 0\n"
            res.write "success.label success\n"
            res.write "success.type DERIVE\n"
            res.write "success.min 0\n"
            res.write "fail.label fail\n"
            res.write "fail.type DERIVE\n"
            res.write "fail.min 0\n"

            res.write "multigraph simpletiles_request_time\n"
            res.write "graph_title Simpletiles request time\n"
            res.write "graph_vlabel ms\n"
            res.write "graph_category simpletiles_request_times\n"
            res.write "mean.label mean\n"
            res.write "mean.type GAUGE\n"
            res.write "mean.min 0\n"
            # res.write "kurtosis.label kurtosis\n"
            # res.write "kurtosis.type GAUGE\n"
            # res.write "kurtosis.min 0\n"
            res.write "stddev.label standard deviation\n"
            res.write "stddev.type GAUGE\n"
            res.write "stddev.min 0\n"
            res.write "skewness.label skewness\n"
            res.write "skewness.type GAUGE\n"
            res.write "skewness.min 0\n"

            $mbtiles_counters.each_key do |project_name|
                next if $project_aliases.key?(project_name)

                res.write "multigraph simpletiles_requests_#{project_name}\n"
                res.write "graph_title Simpletiles request rate (#{project_name})\n"
                res.write "graph_vlabel requests/s\n"
                res.write "graph_category simpletiles_requests\n"

                res.write "#{project_name}_requests.label requests\n"
                res.write "#{project_name}_requests.type DERIVE\n"
                res.write "#{project_name}_requests.min 0\n"
                res.write "#{project_name}_success.label success\n"
                res.write "#{project_name}_success.type DERIVE\n"
                res.write "#{project_name}_success.min 0\n"
                res.write "#{project_name}_fail.label fail\n"
                res.write "#{project_name}_fail.type DERIVE\n"
                res.write "#{project_name}_fail.min 0\n"

                res.write "multigraph simpletiles_request_time_#{project_name}\n"
                res.write "graph_title Simpletiles request time (#{project_name})\n"
                res.write "graph_vlabel ms\n"
                res.write "graph_category simpletiles_request_times\n"
                res.write "#{project_name}_mean.label mean\n"
                res.write "#{project_name}_mean.type GAUGE\n"
                res.write "#{project_name}_mean.min 0\n"
                # res.write "#{project_name}_kurtosis.label kurtosis\n"
                # res.write "#{project_name}_kurtosis.type GAUGE\n"
                # res.write "#{project_name}_kurtosis.min 0\n"
                res.write "#{project_name}_stddev.label standard deviation\n"
                res.write "#{project_name}_stddev.type GAUGE\n"
                res.write "#{project_name}_stddev.min 0\n"
                res.write "#{project_name}_skewness.label skewness\n"
                res.write "#{project_name}_skewness.type GAUGE\n"
                res.write "#{project_name}_skewness.min 0\n"
            end

            res.write "multigraph simpletiles_uptime\n"
            res.write "graph_category simpletiles_uptime\n"
            res.write "graph_title Simpletiles uptime\n"
            res.write "graph_scale no\n"
            res.write "graph_vlabel days\n"
            res.write "uptime.label Client uptime\n"
            res.write "uptime.cdef uptime,86400,/\n"
            res.write "uptime.type GAUGE\n"

            return res.finish
        end

        res.write "multigraph simpletiles_requests\n"
        res.write "requests.value #{$app_request_counter}\nsuccess.value #{$app_success_counter}\nfail.value #{$app_fail_counter}\n"

        res.write "multigraph simpletiles_request_time\n"
        res.write "mean.value #{$app_request_statistics.mean}\n"
        # res.write "kurtosis.value #{$app_request_statistics.kurtosis}\n"
        res.write "stddev.value #{$app_request_statistics.standard_deviation}\n"
        res.write "skewness.value #{$app_request_statistics.skewness}\n"

        $mbtiles_counters.each do |project_name, counters|
            next if $project_aliases.key?(project_name)

            res.write "multigraph simpletiles_requests_#{project_name}\n"
            res.write "#{project_name}_requests.value #{counters[:requests]}\n#{project_name}_success.value #{counters[:success]}\n#{project_name}_fail.value #{counters[:fail]}\n"

            request_statistics = counters[:request_statistics] || RequestStatistics.new
            res.write "multigraph simpletiles_request_time_#{project_name}\n"
            res.write "#{project_name}_mean.value #{request_statistics.mean}\n"
            # res.write "#{project_name}_kurtosis.value #{request_statistics.kurtosis}\n"
            res.write "#{project_name}_stddev.value #{request_statistics.standard_deviation}\n"
            res.write "#{project_name}_skewness.value #{request_statistics.skewness}\n"
        end

        res.write "multigraph simpletiles_uptime\n"
        res.write "uptime.value #{Time.now.to_i - $server_start_time}\n"

        # returns the standard [status, headers, body] array
        res.finish
    end

end
