BASE_DIR = File.dirname(__FILE__)

# Configuration for TCP port checks
config_file = '/etc/simple_tiles.cfg'

configuration = {
    port: 3000,
    hostname: '127.0.0.1'
}

begin
    configuration.merge!(JSON.parse(File.read(config_file), :symbolize_names => true))
rescue Exception => e
end

# God configuration
God.watch do |w|
    w.name          = "SimpleTiles (#{configuration[:hostname]}:#{configuration[:port]})"
    w.interval      = 30.seconds # default      
    w.env           = { "RACK_ENV" => "production" }
    w.start         = "puma -e production -b tcp://#{configuration[:hostname]}:#{configuration[:port]} -w 8 --pidfile #{BASE_DIR}/puma.pid --preload #{BASE_DIR}/config.ru"
    w.stop          = "kill -TERM `cat #{BASE_DIR}/puma.pid`"
    w.restart       = "kill -USR2 `cat #{BASE_DIR}/puma.pid`"
    w.start_grace   = 10.seconds
    w.restart_grace = 10.seconds
    w.w.pid_file    = "#{BASE_DIR}/puma.pid"
    w.log           = "/var/log/simple_tiles/simple_tiles.error.log"
    w.dir           = BASE_DIR
    w.keepalive

    w.uid = 'www-data'
    w.gid = 'www-data'

    w.behavior(:clean_pid_file)

    w.start_if do |start|
        start.condition(:process_running) do |c|
            c.interval = 5.seconds
            c.running  = false
        end
    end

    w.restart_if do |restart|
        restart.condition(:memory_usage) do |c|
            c.above = 512.megabytes
            c.times = 15
        end
  
        restart.condition(:cpu_usage) do |c|
            c.above = 20.percent
            c.times = 15
        end

#        restart.condition(:http_response_code) do |c|
#            c.port = configuration[:port]
#            c.host = configuration[:hostname]
#            c.code_is = 400
#            c.timeout = 10
#            c.path = "/statistics"
#        end
    end

    # lifecycle
    w.lifecycle do |on|
        on.condition(:flapping) do |c|
            c.to_state = [:start, :restart]
            c.times = 5
            c.within = 5.minute
            c.transition = :unmonitored
            c.retry_in = 10.minutes
            c.retry_times = 5
            c.retry_within = 2.hours
        end
    end
end
