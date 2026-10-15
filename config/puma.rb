# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
# On by default in production; SOLID_QUEUE_IN_PUMA=false for a split bin/jobs container
# (lib/tinkerex/solid_queue_in_puma.rb, plain Ruby because this file runs before Rails).
require_relative "../lib/tinkerex/solid_queue_in_puma"
plugin :solid_queue if Tinkerex::SolidQueueInPuma.enabled?

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

# A LIBRARY SCAN RUNS ONCE PUMA IS UP (J, 2026-10-15). The schedule in config/recurring.yml runs
# every 15 minutes on its own clock, so until now a fresh install's first scan could be a quarter of
# an hour away while the guide said "indexed on start" -- measured on a Mac and on Linux: an empty
# catalog twenty seconds after boot, with the folder full. Puma's on_booted runs after the app has
# loaded and the server is listening, which is when the job table exists and the in-Puma worker (or
# a bin/jobs container) can pick the job up. Library::ScanJob.scan_all! carries the backend gate
# (a no-op unless the backend is scannable), and a failure here is logged, never fatal: a boot must
# not die because an enqueue did. Capybara starts its own Puma without this file, so the system
# tests never enqueue one.
on_booted do
  Library::ScanJob.scan_all!
rescue StandardError => e
  Rails.logger.warn("boot scan not enqueued: #{e.class}: #{e.message}")
end
