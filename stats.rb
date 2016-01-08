require 'rubygems'
require 'bundler/setup'
require 'influxdb'

class Stats
  def initialize
    @influxdb = InfluxDB::Client.new(
      'data',
      host: '192.168.99.100',
      username: 'data',
      password: 'data',
      time_precision: 'ms'
    )
  end

  def batch hash
    @influxdb.write_points(hash.to_a.map { |pair|
      {
        series: pair[0].to_s,
        values: { value: pair[1] },
        timestamp: now
      }
    })
  end

  def batch_a array
    @influxdb.write_points(array.map { |hash|
      hash[:timestamp] = now
      hash
    })
  end

  def g key, val
    @influxdb.write_point(key, values: { value: val }, timestamp: now)
  end

  def delgauges pattern
  end

  private

  def now
    (Time.now.to_f * 1000).to_i
  end
end
