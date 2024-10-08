#!/usr/bin/env ruby
require_relative '../../ruby_task_helper/files/task_helper.rb'
require_relative '../lib/puppet_x/encore/patching/http_helper.rb'
require 'time'
require 'json'
require 'open3'

# Bolt task for enabling/disabling monitoring alerts in SolarWinds
class MonitoringPrometheusTask < TaskHelper
  def get_end_timestamp(duration, units)
    case units
    when 'minutes'
      offset = 60
    when 'hours'
      offset = 3600
    when 'days'
      offset = 86_400
    when 'weeks'
      offset = 604_800
    end

    (Time.now.utc + duration * offset).iso8601
  end

  def check_telegraf_service(target, timeout, interval)
    url = "http://#{target}:19100/metrics"
    end_time = Time.now + timeout

    while Time.now < end_time
      command = "curl --silent --head --fail #{url}"
      stdout, stderr, status = Open3.capture3(command)
      return true if status.success?

      sleep(interval)
    end

    false
  end

  # Create a silence for every target that starts now and ends after the given duration
  def create_silences(targets, duration, units, prometheus_server, http_helper)
    silence_ids = []
    ok_targets = []
    failed_targets = {}

    targets.each do |target|
      payload = {
        matchers: [{ name: 'alias', value: target, isRegex: false }],
        startsAt: Time.now.utc.iso8601,
        endsAt: get_end_timestamp(duration, units),
        comment: "Silencing alerts on #{target} for patching",
        createdBy: 'patching',
      }
      headers = { 'Content-Type' => 'application/json' }
      begin
        res = http_helper.post("https://#{prometheus_server}:9093/api/v2/silences",
                                body: payload.to_json,
                                headers: headers)

        ok_targets.push(target) if res.code == '200'
      rescue => e
        failed_targets[target] = e.message
      end
    end

    { ok_targets: ok_targets, failed_targets: failed_targets }
  end

  # Remove all silences for targets that were created by 'patching'
  def remove_silences(targets, prometheus_server, http_helper, timeout, interval)
    ok_targets = []
    failed_targets = {}
    res = http_helper.get("https://#{prometheus_server}:9093/api/v2/silences")
    silences = res.body

    (JSON.parse silences).each do |silence|
      target = silence['matchers'][0]['value']
      # Verify that the current silence is for one of the given targets
      # All silences created by this task will have exactly one matcher
      next if silence['matchers'][0]['name'] != 'alias' || !targets.include?(silence['matchers'][0]['value'])
      # Remove only silences that are active and were created by 'patching'
      if silence['status']['state'] == 'active' && silence['createdBy'] == 'patching'
        if check_telegraf_service(target, timeout, interval)
          begin
            res = http_helper.delete("https://#{prometheus_server}:9093/api/v2/silence/#{silence['id']}")
            ok_targets.push(target) if res.code == '200'
          rescue => e
            failed_targets[target] = e.message
          end
        else
          failed_targets[target] = "Telegraf service not up on #{target} after waiting for #{timeout} seconds"
        end
      end
    end

    { ok_targets: ok_targets, failed_targets: failed_targets }
  end

  # This will either enable or disable monitoring
  def task(targets: nil,
           action: nil,
           prometheus_server: nil,
           silence_duration: nil,
           silence_units: nil,
           ssl_cert: nil,
           ssl_verify: false,
           timeout: 60,
           interval: 5,
           **_kwargs)
    # targets can be either an array or a string with a single target
    # Check if a single target was given and convert it to an array if it was
    if targets.is_a? String
      targets = [targets]
    end

    http_helper = PuppetX::Patching::HTTPHelper.new(ssl: ssl_verify, ca_file: ssl_verify ? ssl_cert : nil)

    if action == 'disable'
      silences_result = create_silences(targets, silence_duration, silence_units, prometheus_server, http_helper)
    elsif action == 'enable'
      silences_result = remove_silences(targets, prometheus_server, http_helper, timeout, interval)
    end

    silences_result
  end
end

MonitoringPrometheusTask.run if $PROGRAM_NAME == __FILE__