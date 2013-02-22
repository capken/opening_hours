require 'json'

# element patterns

module Patterns

  DAY_WORD = '(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Weekday|Weekend)'
  DAY_ABBR_1 = '(?:Mon?|Tue?|Wed?|Thu?|Fri?|Sat?|Sun?)[.]?'
  DAY_ABBR_2 = '(?:M|W|F|Tues|Thur)'

  HOUR_1 = '(?:0?[0-9]|1[0-9]|2[0-4])(?::[0-5][0-9])?\s*(?:[AP]M)?'
  HOUR_2 = '(?:Midnight|Noon)'

  DAY = /\b(#{DAY_WORD}|#{DAY_ABBR_1}|#{DAY_ABBR_2})\b/i
  HOUR = /\b(#{HOUR_1}|#{HOUR_2})\b/i
  LINK = /(to|-|&)/i
  SEPARATOR = /(,|;)/i
  CLOSED = /\bclosed\b/i

  DELIMITER = /\b(?:#{DAY_WORD}|#{DAY_ABBR_1}|#{DAY_ABBR_2}|#{HOUR_1}|#{HOUR_2}|to)\b|[&,;-]|closed/i

  DAY_CANONICALIZE_RULES = {
    /^(?:Monday|Mon?|M)$/i => 'monday',
    /^(?:Tuesday|Tue?|Tues)$/i => 'tuesday',
    /^(?:Wednesday|Wed?|W)$/i => 'wednesday',
    /^(?:Thursday|Thu?|Thur)$/i => 'thursday',
    /^(?:Friday|Fri?|F)$/i => 'friday',
    /^(?:Saturday|Sat?)$/i => 'saturday',
    /^(?:Sunday|Sun?)$/i => 'sunday',
    /^(?:Weekday?)$/i => ['monday', 'tuesday', 'wednesday', 'thursday', 'friday'],
    /^(?:Weekend?)$/i => ['saturday', 'sunday'],
  }
end

# state class

class BaseState
  include Patterns
end

class Start < BaseState
  def process(entity, opening_hours)
    if entity =~ DAY
      opening_hours.reset_day_hour
      opening_hours.day_range.add_day(entity)
      return :DayFound
    end
  end
end

class DayFound < BaseState
  def process(entity, opening_hours)
    case entity
    when LINK
      opening_hours.day_range.add_day_link(entity)
      return :DayLink
    when HOUR
      opening_hours.hour_range.add_from_hour(entity)
      return :HourFrom
    when CLOSED
      opening_hours.reset_day_hour
      return :Start
    end
  end
end

class DayLink < BaseState
  def process(entity, opening_hours)
    case entity
    when DAY
      opening_hours.day_range.add_day(entity)
      return :DayFound
#    when HOUR
#      opening_hours.hour_range.add_from_hour(entity)
#      return :HourFrom
    end
  end
end

class HourFrom < BaseState
  def process(entity, opening_hours)
    case entity
    when LINK
      opening_hours.hour_range.add_hour_link(entity)
      return :HourLink
    end
  end
end

class HourLink < BaseState
  def process(entity, opening_hours)
    case entity
    when HOUR
      opening_hours.hour_range.add_to_hour(entity)
      return :HourTo
    end
  end
end

class HourTo < BaseState
  def process(entity, opening_hours)
    case entity
#    when HOUR
#      opening_hours.add_from_hour(entity)
#      return :HourFrom
    when DAY
      opening_hours.update
      opening_hours.reset_day_hour
      opening_hours.day_range.add_day(entity)
      return :DayFound
    end
  end
end

# utility class

class OpeningHours

  attr_accessor :day_range, :hour_range

  class DayRange
    WEEK = [:monday, :tuesday, :wednesday, :thursday,
      :friday, :saturday, :sunday]
    attr_accessor :days

    def initialize
      @days = []
    end

    def append_day(value)
      if value.is_a? String
        @days << value.to_sym
      elsif value.is_a? Array
        value.each { |v| @days << v.to_sym }
      end
    end

    def add_day(entity)
      last = @days.pop
      if last.nil?
        append_day canonicalize(entity)
      elsif last =~ /^(?:to|-|,|&)$/i
        from_day = @days.pop
        to_day = canonicalize(entity).to_sym
        if from_day.nil?
          append_day to_day
        else
          is_found = false
          WEEK.each do |day|
            is_found = true if day == from_day
            @days << day if is_found
            is_found = false if day == to_day
          end
        end
      else
        append_day canonicalize(entity)
      end
    end

    def add_day_link(entity)
      @days << entity
    end

    def canonicalize(day)
      Patterns::DAY_CANONICALIZE_RULES.each do |key, value|
        return value if day =~ key
      end
      raise "day canonicalize exception with [#{day}]"
    end
  end

  class HourRange
    attr_accessor :from, :to

    def add_from_hour(entity)
      @from = canonicalize(entity)
    end

    def add_hour_link(entity)
    end

    def add_to_hour(entity)
      @to = canonicalize(entity)
    end

    def canonicalize(hour)
      case hour
      when /^(0?[0-9]|1[0-9]|2[0-4])\s*([AP]M)?$/i
        "#{$1}:00 #{$2}".strip.upcase
      when /^noon$/i
        "12:00"
      when /^midnight$/i
        "24:00"
      else
        hour.upcase.gsub(/\s*([AP]M)/i, " \\1")
      end
    end

    def to_s
      "#{from} - #{to}"
    end
  end

  def initialize
    @days = {}
    DayRange::WEEK.each do |day|
      @days[day] = []
    end
  end

  def reset_day_hour
    @day_range = DayRange.new
    @hour_range = HourRange.new
  end

  def update
    @day_range.days.uniq.each do |day|
      @days[day] << @hour_range
    end
  end

  def to_s
    @days.to_json
  end
end

class OpeningHoursStateMachine
  def initialize
    @states = {}
    [:Start, :DayFound, :DayLink, :HourFrom, :HourLink, :HourTo].each do |s|
      @states[s] = Object.const_get(s).new
    end
  end

  def reset
    @state = @states[:Start]
    @opening_hours = OpeningHours.new
  end

  def run(entities)
    reset

    entities.each do |entity|
      next_state = @state.process(entity, @opening_hours)
      if next_state.nil?
        #warn "ignore entity: [#{entity}]"
      else
        @state = @states[next_state]
      end
    end

    @opening_hours.update
    return format_result
  end

  def format_result
    @opening_hours.to_s
  end
end

parser = OpeningHoursStateMachine.new

STDIN.each do |line|
  warn "Input:\t\t\t '#{line.strip}'"
  # TODO: add lookbehind and lookahead in hour pattern
  line = line.strip.gsub(/([AP])\.M\./, '\1M')

  entities = line.scan(Patterns::DELIMITER)
  warn "Entities Segmentation:\t '#{entities.inspect}'"
  result = parser.run entities

  puts "Parsing Results:\t '#{result}'"
  puts "#"*80
end
