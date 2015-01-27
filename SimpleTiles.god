BASE_DIR = File.dirname(__FILE__)

God.watch do |w|
    w.name          = "SimpleTiles"
    w.interval      = 30.seconds # default      
    w.env           = { "RACK_ENV" => "production" }
    w.start         = "#{BASE_DIR}/simple_tiles.rb"
    w.start_grace   = 10.seconds
    w.restart_grace = 10.seconds
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
