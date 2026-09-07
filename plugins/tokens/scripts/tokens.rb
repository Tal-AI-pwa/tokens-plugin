#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads Claude Code session transcripts and renders a usage histogram.
#
# Transcripts live at ~/.claude/projects/<slug>/<session-uuid>.jsonl, one JSON
# object per line. Assistant records carry the API `usage` block, so all
# historical usage is available without any collection step.

require "json"
require "time"
require "date"
require "optparse"
require "stringio"
require "net/http"
require "uri"
require "fileutils"

module ClaudeUsage
  TRANSCRIPTS = File.join(Dir.home, ".claude", "projects")

  # No rates live here. Pricing changes, and a table baked into the CLI goes
  # stale silently on every machine that has not updated. The server holds the
  # single effective-dated copy, so dollars are shown on the website and this
  # command reports token counts only.

  Event = Struct.new(
    :time, :model, :project, :fast,
    :input, :output, :read, :write_5m, :write_1h,
    keyword_init: true
  ) do
    def tokens
      input + output + read + write_5m + write_1h
    end
  end

  # One API response can be written to the transcript several times as the
  # stream progresses; each partial repeats message.id with a growing
  # output_tokens. Keep the largest value seen per id.
  def self.collect
    seen = {}

    Dir.glob(File.join(TRANSCRIPTS, "**", "*.jsonl")).each do |path|
      # Transcripts are UTF-8 whatever the locale is. Without naming it, the
      # line comes back tagged with the platform's default external encoding —
      # US-ASCII under launchd, cron or a hook with no LANG set — and the first
      # non-ASCII byte in a conversation raises out of the parser.
      File.foreach(path, encoding: "UTF-8") do |line|
        record = begin
          JSON.parse(line)
        rescue JSON::ParserError, EncodingError
          next
        end

        next unless record["type"] == "assistant"

        message = record["message"] or next
        usage   = message["usage"]  or next
        model   = message["model"]  or next
        next if model == "<synthetic>"

        id = message["id"] or next
        creation = usage["cache_creation"] || {}

        event = Event.new(
          time:     (Time.parse(record["timestamp"]) rescue next),
          model:    model,
          project:  File.basename(record["cwd"].to_s),
          fast:     usage["speed"] == "fast",
          input:    usage["input_tokens"].to_i,
          output:   usage["output_tokens"].to_i,
          read:     usage["cache_read_input_tokens"].to_i,
          write_5m: creation["ephemeral_5m_input_tokens"].to_i,
          write_1h: creation["ephemeral_1h_input_tokens"].to_i,
        )

        # Fall back to the flat field when the 5m/1h split is absent.
        if event.write_5m.zero? && event.write_1h.zero?
          event.write_5m = usage["cache_creation_input_tokens"].to_i
        end

        prior = seen[id]
        if prior
          event.each_pair do |field, value|
            next unless value.is_a?(Integer)
            prior[field] = value if value > prior[field]
          end
        else
          seen[id] = event
        end
      end
    end

    seen.values.sort_by(&:time)
  end

  # ---- formatting ---------------------------------------------------------

  BLOCKS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"].freeze
  FULL   = "█"

  def self.bar(value, max, width)
    return "" if max <= 0 || value <= 0
    units = (value.to_f / max) * width * 8
    full, rest = (units / 8).floor, (units % 8).round
    full, rest = full + 1, 0 if rest == 8
    bar = (FULL * full) + BLOCKS[rest].to_s
    bar.empty? ? BLOCKS[1] : bar
  end

  def self.tokens(n)
    return n.to_s if n < 1_000
    return "#{(n / 1_000.0).round(n < 10_000 ? 1 : 0)}k" if n < 1_000_000
    "#{(n / 1_000_000.0).round(1)}M"
  end

  # Estimates below a cent read as "$0.00", which looks like free rather than
  # small, so they get a floor instead. Matches the website's usage_money.
  def self.money(amount)
    return "<$0.01" if amount.positive? && amount < 0.01
    "$" + delimit(format("%.2f", amount))
  end

  # Big numbers read better whole; small ones need a decimal or two to say
  # anything at all. A year of heavy use is hundreds of kilograms, a quiet month
  # is a fraction of one, and both have to be legible on the same line.
  def self.carbon(kg)
    precision = if kg.abs >= 100 then 0
    elsif kg.abs >= 10 then 1
    else 2
    end

    delimit(format("%.#{precision}f", kg))
  end

  def self.delimit(number)
    whole, fraction = number.split(".")
    whole = whole.reverse.scan(/\d{1,3}/).join(",").reverse
    fraction ? "#{whole}.#{fraction}" : whole
  end

  def self.color?
    ENV["NO_COLOR"].to_s.empty?
  end

  def self.dim(s)
    color? ? "\e[2m#{s}\e[0m" : s.to_s
  end

  def self.bold(s)
    color? ? "\e[1m#{s}\e[0m" : s.to_s
  end

  def self.ink(s, c)
    color? ? "\e[38;5;#{c}m#{s}\e[0m" : s.to_s
  end

  # Heatmap ramp: four intensity steps plus an empty cell.
  WARM = [95, 130, 173, 215].freeze
  GRAY = [239, 244, 249, 255].freeze
  EMPTY = 238

  # Pad before colorizing — escape codes count toward printf field widths.
  def self.pad(s, n)
    s.to_s.ljust(n)
  end

  def self.rpad(s, n)
    s.to_s.rjust(n)
  end

  def self.width
    cols = ENV["COLUMNS"] || (`tput cols 2>/dev/null`.strip rescue "")
    n = cols.to_i
    n.between?(40, 200) ? n : 80
  end

  def self.rule(width)
    dim("─" * width)
  end

  # ---- calendar heatmap ---------------------------------------------------

  MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
  DAY_LABELS = { 1 => "M", 3 => "W", 5 => "F" }.freeze

  # The grid is always a year, the way the website's is, rather than however
  # many weeks happen to fit the terminal: a card that quietly shows less
  # history in a narrow window disagrees with the site for no stated reason.
  WEEKS = 53

  # Single-letter weekday labels plus a space. Three-letter names cost two more
  # columns for nothing — the rows are read by position, not by name.
  GUTTER = 2

  # What one printed grid occupies, and so the width every other line in the
  # startup card is laid out against.
  GRID_WIDTH = GUTTER + WEEKS

  # Days the calendar window can reach back to. 53 weeks is 371 days, so a
  # 365-day cutoff would trim the leftmost column of the grid it is feeding.
  CALENDAR_DAYS = WEEKS * 7

  # Tokens per local day, for days inside the window. Local date deliberately:
  # a day on the heatmap should mean the day the user was actually working.
  def self.daily_totals(events, first, last)
    daily = Hash.new(0)
    events.each do |e|
      day = e.time.localtime.to_date
      daily[day] += e.tokens if day >= first && day <= last
    end
    daily
  end

  # Intensity is bucketed by quartile of non-empty days, so the scale adapts to
  # whatever range of activity is actually present. Shared with the SVG export,
  # so a cell cannot mean one thing in the terminal and another in a file.
  # Returns nil for a day with nothing on it.
  def self.level_for(daily)
    active = daily.values.reject(&:zero?).sort
    cuts = if active.empty?
      [0, 0, 0]
    else
      [0.25, 0.5, 0.75].map { |q| active[(active.size * q).floor] || active.last }
    end

    lambda do |n|
      return nil if n.zero?
      return 0 if n <= cuts[0]
      return 1 if n <= cuts[1]
      return 2 if n <= cuts[2]
      3
    end
  end

  # A GitHub-style contribution grid: one column per week, one row per weekday.
  def self.calendar(events, weeks: WEEKS, ramp: WARM)
    today = Date.today
    last  = today + (6 - today.wday)          # end of the current week
    first = last - (weeks * 7 - 1)

    daily = daily_totals(events, first, last)
    level = level_for(daily)

    columns = (0...weeks).map { |i| first + (i * 7) }
    pad = " " * GUTTER

    puts pad + month_header(columns)

    (0..6).each do |wday|
      cells = columns.map do |sunday|
        day = sunday + wday
        next [" ", nil] if day > today
        lv = level.call(daily[day])
        lv ? ["█", ramp[lv]] : ["·", EMPTY]
      end
      puts DAY_LABELS.fetch(wday, "").ljust(GUTTER) + run_length(cells)
    end

    puts
    swatch = ramp.map { |c| ink("█", c) }.join
    puts pad + dim("Less ") + swatch + dim(" More")
  end

  # Colorize consecutive same-color cells as one span. A year grid is mostly
  # long runs of empty days, so per-cell escapes would triple the payload for
  # no visual difference — and hook output over 10k chars gets spilled to disk
  # and replaced with a file reference instead of being shown.
  def self.run_length(cells)
    cells.chunk_while { |a, b| a[1] == b[1] }.map do |run|
      glyphs = run.map(&:first).join
      color = run.first[1]
      color ? ink(glyphs, color) : glyphs
    end.join
  end

  def self.month_header(columns)
    row = " " * columns.size
    previous = nil
    columns.each_with_index do |sunday, i|
      month = sunday.month
      if month != previous && sunday.day <= 7 && i <= columns.size - 3
        row[i, 3] = MONTHS[month - 1]
      end
      previous = month
    end
    dim(row.rstrip)
  end

  # ---- export -------------------------------------------------------------

  # Writes the calendar to files anything else on the machine can read: an SVG
  # to look at, a JSON to compute with. Nothing here opens a socket, reads a
  # credential or touches the network — the transcripts are already on this
  # machine, so an export works signed out and offline.
  #
  # Project directory names are deliberately left out of both files. The heatmap
  # is about days, and an export is the kind of thing that ends up pasted into a
  # README, so the safe default is that there is nothing in it to leak.
  module Export
    WEEKS = ClaudeUsage::WEEKS

    # The web page's ramp rather than the terminal's xterm-256 numbers, so a
    # heatmap embedded elsewhere matches the one on the site.
    RAMP = %w[#875f5f #af5f00 #d7875f #ffaf5f].freeze
    EMPTY = "#1e2836"
    BACKGROUND = "#121826"
    LABEL = "#9ca3af"

    CELL = 11
    GAP = 2
    HEADER = 16 # room for the month row above the grid
    FONT = "'Helvetica Neue', Helvetica, Arial, sans-serif"

    # Follows whichever convention the platform already has, rather than
    # inventing one. LOCALAPPDATA is only set on Windows, so this needs no test
    # against RUBY_PLATFORM.
    def self.default_dir
      local = ENV["LOCALAPPDATA"].to_s
      return File.join(local, "tal") unless local.empty?

      base = ENV["XDG_DATA_HOME"].to_s
      base = File.join(Dir.home, ".local", "share") if base.empty?
      File.join(base, "tal")
    end

    def self.run(dir)
      events = ClaudeUsage.collect
      if events.empty?
        warn "No usage found in #{ClaudeUsage::TRANSCRIPTS}."
        return 1
      end

      today = Date.today
      last  = today + (6 - today.wday) # end of the current week
      first = last - (WEEKS * 7 - 1)
      events = events.select { |e| day = e.time.localtime.to_date; day >= first && day <= last }
      daily = ClaudeUsage.daily_totals(events, first, last)

      FileUtils.mkdir_p(dir)
      written = {
        "heatmap.svg" => svg(daily, first, today),
        "usage.json"  => JSON.pretty_generate(summary(events, daily, first, last, today)) + "\n"
      }

      written.each do |name, body|
        path = File.join(dir, name)
        # Binary mode keeps the bytes identical on every platform: text mode
        # would rewrite every newline on Windows.
        File.binwrite(path, body)
        puts path
      end

      0
    end

    def self.svg(daily, first, today)
      level = ClaudeUsage.level_for(daily)
      width  = (WEEKS * (CELL + GAP)) - GAP
      height = HEADER + (7 * (CELL + GAP)) - GAP

      months = []
      cells = []
      previous = nil

      (0...WEEKS).each do |column|
        sunday = first + (column * 7)
        x = column * (CELL + GAP)

        if sunday.month != previous && sunday.day <= 7 && column <= WEEKS - 3
          months << %(<text x="#{x}" y="10">#{ClaudeUsage::MONTHS[sunday.month - 1]}</text>)
        end
        previous = sunday.month

        (0..6).each do |wday|
          day = sunday + wday
          # Days after today hold their place in the grid but are drawn as
          # nothing at all, so the current week keeps its shape.
          next if day > today

          fill = (lv = level.call(daily[day])) ? RAMP[lv] : EMPTY
          y = HEADER + (wday * (CELL + GAP))
          cells << %(<rect x="#{x}" y="#{y}" width="#{CELL}" height="#{CELL}" rx="2" fill="#{fill}"/>)
        end
      end

      total = ClaudeUsage.tokens(daily.values.sum)
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" role="img" aria-label="Claude Code usage over #{WEEKS} weeks: #{total} tokens">
        <title>Claude Code usage — #{total} tokens over #{WEEKS} weeks</title>
        <rect width="#{width}" height="#{height}" fill="#{BACKGROUND}"/>
        <g fill="#{LABEL}" font-family="#{FONT}" font-size="10">#{months.join}</g>
        #{cells.join("\n")}
        </svg>
      SVG
    end

    # Dense: every day in the window, zeros included, so a consumer can draw a
    # grid straight from the array without filling gaps itself.
    #
    # Cost and carbon appear only when a rate card is cached. Omitted rather
    # than zeroed: a consumer can tell "not priced" from "cost nothing", which
    # it could not if the keys were always present.
    def self.summary(events, daily, first, last, today)
      meter = ClaudeUsage::Rates.meter

      by_model = events.group_by(&:model).map { |model, group|
        row = { "model" => model, "tokens" => group.sum(&:tokens), "responses" => group.size }
        row["cost_usd"] = meter.cost(group).round(4) if meter
        row
      }.sort_by { |row| -row["tokens"] }

      totals = {
        "tokens" => daily.values.sum,
        "responses" => events.size,
        "active_days" => daily.values.count(&:positive?)
      }

      if meter
        total = meter.total(events)
        totals["cost_usd"] = total.cost.round(4)
        totals["fully_priced"] = total.fully_priced
        totals["kwh"] = total.kwh.round(4)
        totals["kg_co2e"] = meter.kg_co2e(total).round(4)
      end

      summary = {
        "generated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        # One machine's transcripts. A linked account may hold more.
        "scope" => "this device",
        "window" => { "from" => first.to_s, "to" => last.to_s, "weeks" => WEEKS },
        "totals" => totals,
        "models" => by_model,
        "days" => (first..[today, last].min).map { |day|
          { "date" => day.to_s, "tokens" => daily[day] }
        }
      }

      if meter
        summary["rates"] = {
          "fetched_at" => meter.fetched_at&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "stale" => meter.stale?,
          "grid" => meter.grid_label
        }
      end

      summary
    end
  end

  # ---- sync ---------------------------------------------------------------

  # Reports local totals to a tal account. Everything here is plain HTTP from
  # this process: transcripts are read, summed, and posted on-device. No usage
  # data is ever put in front of a model — the summary the server receives is
  # counts only, and the card that renders locally goes to `systemMessage`,
  # which Claude Code shows the user without adding it to the context window.
  module Sync
    CONFIG = File.join(Dir.home, ".config", "tal", "credentials.json")
    DEFAULT_ENDPOINT = "https://talartificialintelligence.com"
    BATCH = 500
    WINDOW = 400 # days; a little over what the year heatmap draws

    def self.config
      JSON.parse(File.read(CONFIG))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def self.linked?
      !config.nil?
    end

    def self.link(token, endpoint)
      FileUtils.mkdir_p(File.dirname(CONFIG))
      File.write(CONFIG, JSON.pretty_generate("endpoint" => endpoint, "token" => token))
      # The token is a bearer credential for one device; keep it off other
      # accounts on the machine.
      File.chmod(0o600, CONFIG)
    end

    # The cached rates came from this account and cannot be refreshed once the
    # credential is gone, so they go with it rather than aging indefinitely on
    # a machine that can no longer correct them.
    def self.unlink
      Rates.forget
      File.delete(CONFIG)
    rescue Errno::ENOENT
      nil
    end

    # Collapse events to the server's storage grain: one row per local day,
    # model, project and speed tier. Local date, deliberately — a day on the
    # heatmap should mean the day the user was actually working.
    def self.rows(events)
      grouped = Hash.new { |h, k| h[k] = Hash.new(0) }

      events.each do |e|
        local = e.time.localtime
        key = [local.to_date.iso8601, e.model, e.project.to_s, e.fast]
        row = grouped[key]
        row[:input_tokens] += e.input
        row[:output_tokens] += e.output
        row[:cache_read_tokens] += e.read
        row[:cache_write_5m_tokens] += e.write_5m
        row[:cache_write_1h_tokens] += e.write_1h
        row[:response_count] += 1
      end

      grouped.map do |(day, model, project, fast), totals|
        { day: day, model: model, project: project, fast: fast }.merge(totals)
      end
    end

    def self.run(quiet: false)
      settings = config
      unless settings
        warn "Not linked. Run: tokens.rb --link TOKEN" unless quiet
        return 1
      end

      # Before the rows, and whether or not there are any: a machine that has
      # not worked this week still wants current rates for the history it
      # already has.
      Rates.refresh(settings)

      events = ClaudeUsage.collect
      cutoff = Time.now - (WINDOW * 86_400)
      payload = rows(events.select { |e| e.time >= cutoff })

      if payload.empty?
        puts "Nothing to sync." unless quiet
        return 0
      end

      sent = 0
      payload.each_slice(BATCH) do |batch|
        response = post(settings, "/api/usage", days: batch)
        unless response.is_a?(Net::HTTPSuccess)
          warn "Sync failed (#{response.code}): #{response.body.to_s[0, 200]}" unless quiet
          return 1
        end
        sent += batch.size
      end

      puts "Synced #{sent} rows to #{settings['endpoint']}." unless quiet
      0
    end

    def self.post(settings, path, body)
      send_request(settings, Net::HTTP::Post, path) do |request|
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
    end

    def self.get(settings, path)
      send_request(settings, Net::HTTP::Get, path)
    end

    def self.send_request(settings, verb, path)
      uri = URI.join(settings["endpoint"], path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 20

      request = verb.new(uri)
      request["Authorization"] = "Bearer #{settings['token']}"
      yield request if block_given?

      http.request(request)
    rescue StandardError => e
      Struct.new(:code, :body).new("000", e.message)
    end

    # Called from the SessionStart hook. Detached so a slow or unreachable
    # server never delays the session; the hook has already printed its card.
    def self.detach
      return unless linked?

      Process.detach(
        Process.spawn(
          RbConfig.ruby, __FILE__, "--sync", "--quiet",
          out: File::NULL, err: File::NULL
        )
      )
    rescue StandardError
      nil
    end
  end

  # ---- rates --------------------------------------------------------------

  # The pricing and footprint tables, fetched from the linked account and cached
  # on disk.
  #
  # No rates are baked into this file. A table shipped inside a CLI goes stale
  # silently on every machine that has not updated, which is why the terminal
  # showed token counts only for so long. A cache is the same table with two
  # things the baked one could not have: it refreshes itself on every session,
  # and it knows how old it is, so a figure drawn from a month-old copy can say
  # so instead of quietly pretending to be current.
  #
  # The whole effective-dated table comes down, not today's rates, because the
  # card prices a year of history and a day in March has to be priced at March's
  # rate. The arithmetic here is a port of the server's Pricing and
  # UsageFootprint; the two are meant to agree to the cent.
  module Rates
    CACHE = File.join(Dir.home, ".config", "tal", "rates.json")
    VERSION = 1

    # Past this, figures still render but carry a note. Rates change a few times
    # a year, so a month-old copy is very probably right — just not something to
    # assert without saying where it came from.
    STALE_AFTER = 30 * 86_400

    def self.load
      card = JSON.parse(File.read(CACHE))
      return nil unless card["version"] == VERSION
      card
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # Refreshed by the same detached process that syncs, so the tables follow
    # the account without the session ever waiting on the network.
    def self.refresh(settings)
      response = Sync.get(settings, "/api/rates")
      return false unless response.is_a?(Net::HTTPSuccess)

      card = JSON.parse(response.body)
      return false unless card["version"] == VERSION

      card["fetched_at"] = Time.now.to_i
      FileUtils.mkdir_p(File.dirname(CACHE))
      File.write(CACHE, JSON.pretty_generate(card))
      true
    rescue JSON::ParserError, SystemCallError
      false
    end

    def self.forget
      File.delete(CACHE)
    rescue Errno::ENOENT
      nil
    end

    # Nil when there is nothing cached, which is the signal to draw the card the
    # way it looked before any of this existed: tokens only, no apology.
    def self.meter
      card = load
      card && Meter.new(card)
    end
  end

  # Dollars and kilowatt-hours for a set of events, from a cached rate card.
  class Meter
    Rate = Struct.new(:input, :output, :known, keyword_init: true)
    Total = Struct.new(:cost, :kwh, :fully_priced, keyword_init: true) do
      def kg_co2e_with(grams_per_kwh)
        (kwh * grams_per_kwh) / 1000.0
      end
    end

    PER_MTOK = 1_000_000.0

    attr_reader :card

    def initialize(card)
      @card = card
      @pricing = card["pricing"] || {}
      @footprint = card["footprint"] || {}
      @models = @pricing["models"] || []
      @rates = {}
    end

    def fetched_at
      stamp = card["fetched_at"]
      stamp && Time.at(stamp)
    end

    def age
      at = fetched_at
      at ? (Time.now - at) : nil
    end

    def stale?
      seconds = age
      !seconds.nil? && seconds > Rates::STALE_AFTER
    end

    def stale_days
      seconds = age
      seconds && (seconds / 86_400).floor
    end

    def grid_label
      @footprint["grid_label"]
    end

    def total(events)
      cost = 0.0
      kwh = 0.0
      priced = true

      events.each do |event|
        rate = rate_for(event)
        priced = false unless rate.known
        cost += cost_of(event, rate)
        kwh += kwh_of(event)
      end

      Total.new(cost: cost, kwh: kwh, fully_priced: priced)
    end

    def kg_co2e(total)
      total.kg_co2e_with(@footprint["g_co2e_per_kwh"].to_f)
    end

    def cost(events)
      total(events).cost
    end

    private
      def cost_of(event, rate)
        input_side =
          event.input +
          (event.read * @pricing["cache_read"].to_f) +
          (event.write_5m * @pricing["cache_write_5m"].to_f) +
          (event.write_1h * @pricing["cache_write_1h"].to_f)

        ((input_side * rate.input) + (event.output * rate.output)) / PER_MTOK
      end

      def kwh_of(event)
        tier = @footprint.dig("wh_per_ktok", tier_for(event.model)) || {}

        input_side =
          event.input +
          (event.read * @footprint["cache_read"].to_f) +
          ((event.write_5m + event.write_1h) * @footprint["cache_write"].to_f)

        watt_hours = ((input_side * tier["input"].to_f) + (event.output * tier["output"].to_f)) / 1_000.0
        watt_hours / 1_000.0
      end

      # Fast mode is the same model answering sooner, so it draws the same tier.
      def tier_for(model)
        name = model.to_s.downcase
        _, tier = (@footprint["tiers"] || {}).find { |needle, _| name.include?(needle) }
        tier || @footprint["fallback_tier"]
      end

      def rate_for(event)
        day = event.time.localtime.to_date.to_s
        key = [event.model, event.fast, day]
        return @rates[key] if @rates.key?(key)

        row = lookup(event.model, event.fast, day)
        # A fast row with no premium rate on file falls back to the standard rate
        # for the same model before giving up on the model entirely.
        row ||= lookup(event.model, false, day) if event.fast

        @rates[key] = if row
          Rate.new(input: row["input"].to_f, output: row["output"].to_f, known: true)
        else
          fallback = @pricing["fallback"] || {}
          Rate.new(input: fallback["input"].to_f, output: fallback["output"].to_f, known: false)
        end
      end

      # Mirrors ModelPrice.for. Clients report whatever the API called the model,
      # which is often a dated id like "claude-haiku-4-5-20251001", while rates
      # are stored under the undated family name. An exact miss falls back to the
      # longest family name the id starts with — longest so that a future
      # "claude-opus-4-5-…" cannot match a bare "claude-opus-4".
      def lookup(model, fast, day)
        candidates = @models.select do |row|
          row["fast"] == fast &&
            row["starts_on"].to_s <= day &&
            (row["ends_on"].nil? || row["ends_on"].to_s >= day)
        end

        exact = candidates.select { |row| row["model"] == model }
        return exact.max_by { |row| row["starts_on"].to_s } if exact.any?

        family = candidates.select { |row| model.to_s.start_with?("#{row['model']}-") }
        family.max_by { |row| [row["model"].to_s.length, row["starts_on"].to_s] }
      end
  end

  # ---- report -------------------------------------------------------------

  def self.run(argv)
    options = {
      days: 14, bucket: :day, project: nil, view: :bars, ramp: WARM,
      hook: false, endpoint: ENV["TAL_URL"] || Sync::DEFAULT_ENDPOINT
    }

    OptionParser.new do |o|
      o.banner = "usage: tokens.rb [options]"
      o.on("--days N", Integer, "Days to chart (default 14; #{CALENDAR_DAYS} for --calendar)") do |v|
        options[:days] = v
        options[:days_set] = true
      end
      o.on("--weeks", "Bucket by week instead of day")        { options[:bucket] = :week }
      o.on("--all", "Chart all recorded history")             { options[:days] = 10_000 }
      o.on("--project NAME", "Limit to one project directory") { |v| options[:project] = v }
      o.on("--calendar", "Year-at-a-glance heatmap instead of bars") { options[:view] = :calendar }
      o.on("--mono", "Grayscale heatmap ramp")                 { options[:ramp] = GRAY }
      o.on("--hook", "Emit SessionStart hook JSON (internal)") { options[:hook] = true }

      o.separator ""
      o.on("--export [DIR]", "Write heatmap.svg and usage.json (default #{Export.default_dir})") do |v|
        options[:export] = (v.nil? || v.empty?) ? Export.default_dir : v
      end

      o.separator ""
      o.on("--link TOKEN", "Link this machine to a tal account") { |v| options[:link] = v }
      o.on("--unlink", "Forget the linked account")              { options[:unlink] = true }
      o.on("--sync", "Report local totals to the linked account") { options[:sync] = true }
      o.on("--rates", "Refresh the cached pricing and carbon tables") { options[:rates] = true }
      o.on("--endpoint URL", "Server to link against (default #{Sync::DEFAULT_ENDPOINT})") do |v|
        options[:endpoint] = v
      end
      o.on("--quiet", "Suppress sync output")                    { options[:quiet] = true }
    end.parse!(argv)

    return startup_card(options) if options[:hook]

    if options[:link]
      Sync.link(options[:link], options[:endpoint])
      puts "Linked to #{options[:endpoint]}. Syncing now."
      return Sync.run(quiet: false)
    end

    if options[:unlink]
      Sync.unlink
      puts "Unlinked. Nothing further will be reported."
      return
    end

    return exit(Sync.run(quiet: !!options[:quiet])) if options[:sync]

    if options[:rates]
      settings = Sync.config
      unless settings
        warn "Not linked. Run: tokens.rb --link TOKEN"
        return exit(1)
      end
      unless Rates.refresh(settings)
        warn "Could not fetch rates from #{settings['endpoint']}."
        return exit(1)
      end
      puts "Rates updated from #{settings['endpoint']}."
      return exit(0)
    end

    # Always the full year, whatever --days says: the export is a file someone
    # else will draw, not this terminal's width.
    return exit(Export.run(options[:export])) if options[:export]

    # The calendar spans a year of columns, so widen the window unless the
    # caller asked for a specific one.
    options[:days] = CALENDAR_DAYS if options[:view] == :calendar && !options[:days_set]

    events = collect
    if events.empty?
      puts "No usage found in #{TRANSCRIPTS}."
      return
    end

    if options[:project]
      events = events.select { |e| e.project == options[:project] }
      if events.empty?
        puts "No usage found for project #{options[:project]}."
        return
      end
    end

    cutoff = Time.now - (options[:days] * 86_400)
    events = events.select { |e| e.time >= cutoff }
    if events.empty?
      puts "No usage in the last #{options[:days]} days."
      return
    end

    w = width
    options[:meter] = Rates.meter

    if options[:view] == :calendar
      puts
      calendar(events, ramp: options[:ramp])
      puts
      puts summary_line(events)
      line = meter_line(events, options[:meter])
      puts line if line
      puts
    else
      report(events, options, w)
    end
  end

  def self.summary_line(events)
    top = events.group_by(&:model).max_by { |_, evts| evts.sum(&:tokens) }&.first
    days = events.map { |e| e.time.localtime.to_date }.uniq.size
    [
      bold(tokens(events.sum(&:tokens))) + dim(" tokens"),
      dim("#{events.size} responses"),
      dim("#{days} active #{days == 1 ? 'day' : 'days'}"),
      dim(top.to_s),
      # The website adds up every linked machine; this reads one machine's
      # transcripts and cannot see the others. Said plainly so the two numbers
      # disagreeing looks like arithmetic rather than a bug.
      dim("from this device"),
    ].join(dim("  ·  "))
  end

  # Dollars and carbon, on their own line under the summary. Nil when no rate
  # card has been fetched — an unlinked or never-synced machine draws the card
  # exactly as it did before any of this existed.
  def self.meter_line(events, meter)
    return nil unless meter

    total = meter.total(events)
    parts = [
      dim("≈") + bold(money(total.cost)),
      bold(carbon(meter.kg_co2e(total))) + dim(" kg CO₂e"),
    ]

    # The same caveat the website prints: a model with no rate on file is priced
    # at the Opus-tier fallback, so the figure is an over-estimate rather than a
    # measurement.
    parts << dim("some models unpriced") unless total.fully_priced
    parts << dim("rates #{meter.stale_days} days old") if meter.stale?

    parts.join(dim("  ·  "))
  end

  # Rendered by the SessionStart hook. Emits hook JSON on stdout: the card goes
  # in `systemMessage` (shown to the user) and never into the model's context.
  def self.startup_card(options)
    return unless ENV["CLAUDE_TOKENS_NO_STARTUP"].to_s.empty?

    Sync.detach

    events = collect
    return if events.empty?

    cutoff = Time.now - (CALENDAR_DAYS * 86_400)
    events = events.select { |e| e.time >= cutoff }
    return if events.empty?

    total = events.sum(&:tokens)
    meter = Rates.meter
    card = capture do
      calendar(events, ramp: options[:ramp])
      puts
      puts summary_line(events)
      line = meter_line(events, meter)
      puts line if line
      puts
      breakdown("By model", events.group_by(&:model), total, GRID_WIDTH, limit: TOP_N, meter: meter)
      puts
      breakdown("By project", events.group_by(&:project), total, GRID_WIDTH, limit: TOP_N, meter: meter)
    end

    # Claude Code renders a systemMessage as "<hookName> says: <content>" in a
    # single wrapping Text node. Leading with a newline pushes the grid past
    # that prefix so every row starts at column 0 instead of row 1 being
    # shifted right by the label.
    puts JSON.generate(
      "systemMessage" => "\n" + card,
      "suppressOutput" => true
    )
  end

  def self.capture
    previous = $stdout
    buffer = StringIO.new
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = previous
  end

  def self.report(events, options, w)
    total_tokens = events.sum(&:tokens)
    meter        = options[:meter]
    span         = "#{events.first.time.localtime.strftime('%b %-d')} – #{events.last.time.localtime.strftime('%b %-d, %Y')}"

    puts
    puts bold("Claude Code usage") + dim("   #{span}")
    puts rule(w)
    puts

    histogram(events, options, w)
    puts
    breakdown("By model", events.group_by(&:model), total_tokens, w, meter: meter)
    puts
    breakdown("By project", events.group_by(&:project), total_tokens, w, meter: meter)
    puts

    puts rule(w)
    footer = [
      dim(pad("#{events.size} responses", [w - 9 - (meter ? MONEY_W : 0), 10].max)),
      bold(rpad(tokens(total_tokens), 7)),
    ]
    footer << " " << bold(rpad(money(meter.total(events).cost), MONEY_W - 1)) if meter
    puts footer.join

    line = meter_line(events, meter)
    puts line if line
    puts
  end

  def self.histogram(events, options, w)
    fmt, label = if options[:bucket] == :week
      [->(t) { (t.localtime.to_date - t.localtime.to_date.wday).strftime("%b %-d") }, "tokens per week"]
    else
      [->(t) { t.localtime.strftime("%a %b %-d") }, "tokens per day"]
    end

    buckets = events.group_by { |e| fmt.call(e.time) }
    ordered = buckets.sort_by { |_, evts| evts.first.time }

    key_w  = ordered.map { |k, _| k.length }.max
    bar_w  = [w - key_w - 13, 10].max
    max    = ordered.map { |_, evts| evts.sum(&:tokens) }.max

    puts dim(rpad(label, key_w + bar_w + 11))
    ordered.each do |key, evts|
      tok = evts.sum(&:tokens)
      puts [
        dim(pad(key, key_w)),
        "  ",
        pad(bar(tok, max, bar_w), bar_w),
        " ",
        rpad(tokens(tok), 7),
      ].join
    end
  end

  # The startup card has a height budget the full report does not, so it caps
  # each breakdown the same way the website does and rolls the tail into one
  # line rather than letting a machine with forty project directories push the
  # grid off the top of the scrollback.
  TOP_N = 5

  # Cost gets its own column when a rate card is cached, the way the website's
  # breakdown tables carry one, and the bars give up the width to pay for it.
  MONEY_W = 10

  def self.breakdown(title, groups, total_tokens, w, limit: nil, meter: nil)
    rows = groups.map { |key, evts| [key, evts.sum(&:tokens), meter && meter.cost(evts)] }
                 .sort_by { |row| -row[1] }

    rest = limit ? rows.drop(limit) : []
    rows = rows.first(limit) if limit

    key_w = rows.map { |row| row[0].length }.max
    bar_w = [w - key_w - 19 - (meter ? MONEY_W : 0), 8].max

    puts bold(title)
    rows.each do |key, tok, cost|
      share = total_tokens.zero? ? 0 : (tok * 100.0 / total_tokens).round
      line = [
        pad(key, key_w),
        "  ",
        dim(pad(bar(tok, rows.first[1], bar_w), bar_w)),
        " ",
        rpad("#{share}%", 5),
        " ",
        rpad(tokens(tok), 7),
      ]
      line << " " << dim(rpad(money(cost), MONEY_W - 1)) if meter
      puts line.join
    end

    return if rest.empty?
    tail = "+ #{rest.size} more, #{tokens(rest.sum { |row| row[1] })}"
    tail += ", #{money(rest.sum { |row| row[2] })}" if meter
    puts dim(tail)
  end
end

ClaudeUsage.run(ARGV) if $PROGRAM_NAME == __FILE__
