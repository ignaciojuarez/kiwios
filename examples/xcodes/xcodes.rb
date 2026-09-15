#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

class CheckError < StandardError; end

SUPPORTED_MIN = [2, 1, 0].freeze
SUPPORTED_MAX = [2, 1, 99].freeze
MAX_ROWS = 100
MAX_STATE_BYTES = 44 * 1024
CATALOG_ARCHITECTURES = "Apple Silicon|Universal|Intel"

def capture(*argv, env: {})
  stdout, stderr, status = Open3.capture3(env, *argv)
  unless status.success?
    diagnostic = "#{stdout}\n#{stderr}".downcase
    reason = if diagnostic.match?(/network|internet|offline|timed out|could not (resolve|connect)|not connected/)
               "; network or catalog service is unavailable"
             elsif diagnostic.match?(/license|first launch/)
               "; Xcode license or first-launch setup is required on the Mac"
             elsif diagnostic.match?(/authenticate|authentication|apple id|sign[ -]?in|verification code/)
               "; Apple authentication is required on the Mac"
             elsif diagnostic.match?(/no space|disk full|insufficient space/)
               "; disk space is insufficient"
             else
               ""
             end
    raise CheckError, "#{argv.first} failed (exit #{status.exitstatus || "unknown"})#{reason}"
  end

  stdout
rescue Errno::ENOENT
  raise CheckError, "#{argv.first} is not installed or is not on PATH"
end

def capture_xcodes(*arguments)
  data_dir = ENV["KIWIOS_DATA_DIR"]
  raise CheckError, "KIWIOS_DATA_DIR is unavailable" unless data_dir && !data_dir.empty?

  home = File.join(data_dir, "xcodes-home")
  FileUtils.mkdir_p(home, mode: 0o700)
  capture("xcodes", *arguments, env: { "HOME" => home })
end

def event(type, message, state = nil)
  value = { "t" => type, "msg" => message }
  value["state"] = state if state
  puts JSON.generate(value)
end

def version_parts(value)
  match = value.strip.match(/\A(\d+)\.(\d+)\.(\d+)(?:[-+].*)?\z/)
  match && match.captures.map(&:to_i)
end

def xcodes_version
  value = capture_xcodes("version", "--no-color").strip
  raise CheckError, "xcodes returned an unrecognised version" unless version_parts(value)

  value
end

def supported_version?(value)
  parts = version_parts(value)
  parts && (parts <=> SUPPORTED_MIN) >= 0 && (parts <=> SUPPORTED_MAX) <= 0
end

def require_supported_catalog!
  version = xcodes_version
  return version if supported_version?(version)

  raise CheckError, "xcodes #{version} has not been fixture-tested; catalog parsing is unavailable"
end

def host_architecture
  if RUBY_PLATFORM.include?("arm64")
    "Apple Silicon"
  elsif RUBY_PLATFORM.include?("x86_64")
    "Intel"
  else
    "Host default"
  end
end

def developer_path
  path = capture("xcode-select", "--print-path").strip
  raise CheckError, "xcode-select returned an empty developer directory" if path.empty?

  path
end

def inconclusive_first_launch_probe?(diagnostic, status)
  status.exitstatus == 64 || diagnostic.match?(/unknown argument|unrecognized option|invalid option|usage:/)
end

def require_prompt_free_developer_tools!(developer_dir)
  stdout, stderr, status = Open3.capture3({ "DEVELOPER_DIR" => developer_dir }, "xcodebuild", "-checkFirstLaunchStatus")
  return if status.success?
  return if inconclusive_first_launch_probe?("#{stdout}\n#{stderr}".downcase, status)

  raise CheckError, "xcodebuild failed (exit #{status.exitstatus || "unknown"}); Xcode license or first-launch setup is required on the Mac"
rescue Errno::ENOENT
  raise CheckError, "xcodebuild is not installed or is not on PATH"
end

def inspect_xcode(path)
  app = path.sub(%r{/Contents/Developer/?\z}, "")
  plist = File.join(app, "Contents", "Info.plist")
  raise CheckError, "developer directory is not a full Xcode: #{path}" unless File.file?(plist)

  allowed = File.expand_path(app).start_with?("/Applications/")
  fixture_root = ENV["KIWIOS_XCODES_FIXTURE_ROOT"]
  allowed ||= fixture_root && File.expand_path(app).start_with?("#{File.expand_path(fixture_root)}/")
  raise CheckError, "Xcode is outside the disclosed /Applications directory: #{app}" unless allowed

  bundle_id = capture("plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist).strip
  raise CheckError, "#{app} is not an Xcode application" unless bundle_id == "com.apple.dt.Xcode"

  dev = File.join(app, "Contents", "Developer")
  require_prompt_free_developer_tools!(dev)
  output = capture("xcodebuild", "-version", env: { "DEVELOPER_DIR" => dev })
  version = output[/^Xcode\s+(.+)$/, 1]
  build = output[/^Build version\s+(.+)$/, 1]
  raise CheckError, "#{app} returned unrecognised Xcode metadata" unless version && build

  { "version" => version.strip, "build" => build.strip, "path" => app, "developer" => dev }
end

def installed_xcodes
  selected = developer_path
  output = capture_xcodes("installed", "--no-color")
  paths = output.lines.reject { |line| line.strip.empty? }.map do |line|
    fields = line.chomp.split("\t", -1)
    raise CheckError, "xcodes installed returned an unrecognised row" unless fields.length == 2 && fields[1].start_with?("/")

    fields[1]
  end

  paths.uniq.sort.map do |path|
    item = inspect_xcode(path)
    item["selected"] = File.expand_path(item["developer"]) == File.expand_path(selected)
    item
  end
end

def row_id(prefix, *values)
  "#{prefix}-#{Digest::SHA256.hexdigest(values.join("\0"))[0, 12]}"
end

def emit_table(message, columns, rows, newest: false, total: nil)
  total ||= rows.length
  shown = newest ? rows.last(MAX_ROWS) : rows.first(MAX_ROWS)
  state = { "columns" => columns, "rows" => shown }
  while shown.any? && JSON.generate(state).bytesize > MAX_STATE_BYTES
    newest ? shown.shift : shown.pop
    state = { "columns" => columns, "rows" => shown }
  end
  omitted = total - shown.length
  suffix = omitted.positive? ? "; showing #{shown.length} of #{total}" : ""
  event(omitted.positive? ? "warn" : "ok", "#{message}#{suffix}", state)
end

def interleave_groups(groups)
  shown = []
  max = groups.map(&:length).max || 0
  max.times do |index|
    groups.each do |group|
      shown << group[index] if index < group.length
    end
  end
  shown
end

def check_tool_health
  version = xcodes_version
  state = { "value" => supported_version?(version) ? "Ready" : "Untested", "detail" => "xcodes #{version}; authentication status unknown" }
  if supported_version?(version)
    event("ok", "xcodes #{version} is ready", state)
  else
    event("warn", "xcodes #{version} is installed but its catalog output is untested", state)
  end
end

def check_selected_xcode
  item = inspect_xcode(developer_path)
  event("ok", "Xcode #{item["version"]} (#{item["build"]}) is selected", {
    "value" => "Xcode #{item["version"]}", "detail" => item["developer"]
  })
end

def check_installed_xcodes
  rows = installed_xcodes.map do |item|
    {
      "id" => row_id("xcode", item["path"]), "version" => item["version"], "build" => item["build"],
      "path" => item["path"], "selected" => item["selected"]
    }
  end
  emit_table("#{rows.length} Xcode installation#{rows.length == 1 ? "" : "s"}", [
    { "id" => "version", "label" => "Version" }, { "id" => "build", "label" => "Build" },
    { "id" => "path", "label" => "Path" }, { "id" => "selected", "label" => "Selected" }
  ], rows)
end

def catalog_xcode_row(line)
  markers = []
  if line.sub!(/ \((Installed)(?:, (Selected))?\)\z/, "")
    markers = Regexp.last_match.captures.compact
  elsif line.sub!(/ \((Selected)\)\z/, "")
    markers = ["Selected"]
  end
  match = line.match(/\A(.+?) \(([^()]+)\)(?: \[(#{CATALOG_ARCHITECTURES})\])?\z/)
  raise CheckError, "xcodes list returned an unrecognised row" unless match

  version, build, architectures = match.captures
  channel = if version.downcase.include?("beta")
              "Beta"
            elsif version.downcase.include?("candidate") || version.downcase.include?("rc")
              "Release candidate"
            else
              "Stable"
            end
  {
    "id" => row_id("xcode", version, build, architectures.to_s), "version" => version, "build" => build,
    "channel" => channel, "architectures" => architectures || "", "installed" => markers.include?("Installed")
  }
end

def check_available_xcodes
  require_supported_catalog!
  lines = capture_xcodes("list", "--no-color").lines.map(&:strip)
  rows = lines.reject { |line| line.empty? || line.start_with?("Showing Xcodes ") || line.start_with?("Switch with ") }.map { |line| catalog_xcode_row(line) }
  emit_table("#{rows.length} Xcode releases available", [
    { "id" => "version", "label" => "Version" }, { "id" => "build", "label" => "Build" },
    { "id" => "channel", "label" => "Channel" }, { "id" => "architectures", "label" => "Architectures" },
    { "id" => "installed", "label" => "Installed" }
  ], rows, newest: true)
end

def simctl_json(item, *arguments)
  output = capture("xcrun", "simctl", *arguments, env: { "DEVELOPER_DIR" => item["developer"] })
  JSON.parse(output)
rescue JSON::ParserError
  raise CheckError, "simctl returned invalid JSON for Xcode #{item["version"]}"
end

def check_installed_runtimes
  rows = installed_xcodes.flat_map do |item|
    data = simctl_json(item, "list", "runtimes", "--json")
    runtimes = data["runtimes"]
    raise CheckError, "simctl returned an unrecognised runtime inventory" unless runtimes.is_a?(Array)

    runtimes.map do |runtime|
      raise CheckError, "simctl returned an incomplete runtime" unless runtime.is_a?(Hash) && runtime["identifier"] && runtime["name"]

      {
        "id" => row_id("runtime", item["developer"], runtime["identifier"]),
        "platform" => runtime["name"].to_s.split.first, "version" => runtime["version"].to_s,
        "identifier" => runtime["identifier"].to_s, "available" => runtime["isAvailable"] == true,
        "support" => runtime["isAvailable"] == true ? "Supported" : runtime.fetch("availabilityError", "Unavailable").to_s,
        "developer" => item["developer"]
      }
    end
  end
  emit_table("#{rows.length} installed simulator runtimes found", [
    { "id" => "platform", "label" => "Platform" }, { "id" => "version", "label" => "Version" },
    { "id" => "identifier", "label" => "Identifier" }, { "id" => "available", "label" => "Available" },
    { "id" => "support", "label" => "Support" }, { "id" => "developer", "label" => "Developer Directory" }
  ], rows)
end

def devices_for_xcode(item)
  data = simctl_json(item, "list", "devices", "--json")
  devices = data["devices"]
  raise CheckError, "simctl returned an unrecognised device inventory" unless devices.is_a?(Hash)

  devices.flat_map do |runtime, values|
    raise CheckError, "simctl returned an incomplete device inventory" unless values.is_a?(Array)

    values.map do |device|
      raise CheckError, "simctl returned an incomplete device" unless device.is_a?(Hash) && device["udid"] && device["name"] && device["state"]

      {
        "id" => row_id("device", item["developer"], device["udid"]), "name" => device["name"].to_s,
        "udid" => device["udid"].to_s, "runtime" => runtime.to_s, "state" => device["state"].to_s,
        "available" => device["isAvailable"] == true, "developer" => item["developer"]
      }
    end
  end
end

def check_simulator_devices
  groups = installed_xcodes.map { |item| devices_for_xcode(item) }
  rows = interleave_groups(groups)
  emit_table("#{rows.length} simulator devices found", [
    { "id" => "name", "label" => "Name" }, { "id" => "udid", "label" => "UDID" },
    { "id" => "runtime", "label" => "Runtime" }, { "id" => "state", "label" => "State" },
    { "id" => "available", "label" => "Available" }, { "id" => "developer", "label" => "Developer Directory" }
  ], rows)
end

def available_runtime_row(platform, line)
  status = "Available"
  if line.sub!(/ \((Bundled with selected Xcode|Installed)\)\z/, "")
    status = Regexp.last_match(1)
  end
  raise CheckError, "xcodes runtimes returned an unrecognised row" unless line.start_with?("#{platform} ")

  rest = line.sub(/\A#{Regexp.escape(platform)}\s+/, "")
  architecture = host_architecture
  build = nil
  if rest.sub!(/ \(([^()]+)\)\z/, "")
    build = Regexp.last_match(1)
  end
  if rest.sub!(/ \[(#{CATALOG_ARCHITECTURES})\]\z/, "")
    architecture = Regexp.last_match(1)
  end
  raise CheckError, "xcodes runtimes returned an unrecognised row" if rest.empty? || rest.match?(/[\[\]()]/)

  version = build ? "#{rest} (#{build})" : rest
  channel = version.downcase.include?("beta") ? "Beta" : "Stable"
  {
    "id" => row_id("runtime", line, status), "platform" => platform, "version" => version,
    "channel" => channel, "architecture" => architecture, "status" => status
  }
end

def check_available_runtimes
  require_supported_catalog!
  platform = nil
  rows = []
  capture_xcodes("runtimes", "--include-betas", "--no-color").each_line do |raw|
    line = raw.strip
    next if line.empty? || line.start_with?("Note:") || line.start_with?("Showing runtimes ")
    if (match = line.match(/\A-- (.+) --\z/))
      platform = match[1]
      next
    end
    raise CheckError, "xcodes runtimes returned data before a platform heading" unless platform

    rows << available_runtime_row(platform, line)
  end
  emit_table("#{rows.length} simulator runtime releases available", [
    { "id" => "platform", "label" => "Platform" }, { "id" => "version", "label" => "Version" },
    { "id" => "channel", "label" => "Channel" }, { "id" => "architecture", "label" => "Architecture Filter" },
    { "id" => "status", "label" => "Status" }
  ], rows, newest: true)
end

checks = {
  "tool-health" => method(:check_tool_health), "selected-xcode" => method(:check_selected_xcode),
  "installed-xcodes" => method(:check_installed_xcodes), "available-xcodes" => method(:check_available_xcodes),
  "installed-runtimes" => method(:check_installed_runtimes), "simulator-devices" => method(:check_simulator_devices),
  "available-runtimes" => method(:check_available_runtimes)
}

begin
  check = checks[ARGV.fetch(0, "")]
  raise CheckError, "unknown Xcodes check" unless check
  check.call
rescue CheckError => error
  event("error", error.message)
  exit 2
end
