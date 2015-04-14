# Common variables
BASE_DIR   = File.dirname(__FILE__)
PID_DIR    = "/var/run/simple_tiles"
PID_FILE   = File.join(PID_DIR, "puma.pid")
STATE_FILE = File.join(PID_DIR, "puma.state")
CTL_FILE   = "unix://" + File.join(PID_DIR, "puma.ctl")

PUMA_PATH  = "/home/simpletiles/.rvm/bin/bootup_puma"
PUMACTL_PATH  = "/home/simpletiles/.rvm/bin/bootup_pumactl"

SIMPLETILES_USER  = "simpletiles"
SIMPLETILES_GROUP = "simpletiles"

# Create the directory for the PID
FileUtils.mkdir_p PID_DIR
FileUtils.chown SIMPLETILES_USER, SIMPLETILES_GROUP, PID_DIR

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
    w.start         = "#{PUMA_PATH} -C #{BASE_DIR}/puma.rb"
    w.stop          = "#{PUMACTL_PATH} -S #{STATE_FILE} stop"
    w.restart       = "#{PUMACTL_PATH} -S #{STATE_FILE} restart"
    w.start_grace   = 10.seconds
    w.restart_grace = 10.seconds
    w.pid_file      = PID_FILE
    w.log           = "/var/log/simple_tiles/simple_tiles.error.log"
    w.dir           = BASE_DIR
    w.keepalive

    w.uid = SIMPLETILES_USER
    w.gid = SIMPLETILES_GROUP

    w.behavior(:clean_pid_file)

    w.start_if do |start|
        start.condition(:process_running) do |c|
            c.interval = 5.seconds
            c.running  = false
        end
    end

    w.restart_if do |restart|
        restart.condition(:memory_usage) do |c|
            c.above = 1024.megabytes
            c.times = 15
        end
  
        restart.condition(:cpu_usage) do |c|
            c.above = 75.percent
            c.times = 15
        end

        restart.condition(:process_exits)

        restart.condition(:socket_responding) do |c|
            c.port = configuration[:port]
            c.addr = configuration[:hostname]
            c.family = 'tcp'
        end
    end

    # lifecycle
    w.lifecycle do |on|
        on.condition(:flapping) do |c|
            c.to_state = [:start, :restart]
            c.times = 5
            c.within = 5.minute
            c.transition = :unmonitored
            c.retry_in = 5.minutes
            c.retry_times = 5
            c.retry_within = 1.hours
        end
    end
end
