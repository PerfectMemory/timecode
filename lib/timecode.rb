# Timecode is a convenience object for calculating SMPTE timecode natively. 
# The promise is that you only have to store two values to know the timecode - the amount
# of frames and the framerate. An additional perk might be to save the dropframeness,
# but we avoid that at this point.
#
# You can calculate in timecode objects ass well as with conventional integers and floats.
# Timecode is immutable and can be used as a value object. Timecode objects are sortable.
#
# Here's how to use it with ActiveRecord (your column names will be source_tc_frames_total and tape_fps)
#
#   composed_of :source_tc, :class_name => 'Timecode',
#     :mapping => [%w(source_tc_frames total), %w(tape_fps fps)]

class Timecode
  VERSION = '0.1.4'

  include Comparable
  
  DEFAULT_FPS = 25.0
  
  #:stopdoc:
  NTSC_FPS = (30.0 * 1000 / 1001).freeze
  ALLOWED_FPS_DELTA = (0.001).freeze
  
  COMPLETE_TC_RE = /^(\d{2}):(\d{2}):(\d{2}):(\d{2})$/
  DF_TC_RE = /^(\d{1,2}):(\d{1,2}):(\d{1,2});(\d{2})$/
  FRACTIONAL_TC_RE = /^(\d{2}):(\d{2}):(\d{2}).(\d{1,8})$/
  
  WITH_FRACTIONS_OF_SECOND = "%02d:%02d:%02d.%02d"
  WITH_FRAMES = "%02d:%02d:%02d:%02d"
  #:startdoc:
  
  # All Timecode lib errors inherit from this
  class Error < RuntimeError; end
  
  # Will be raised for functions that are not supported
  class TimecodeLibError < Error; end

  # Gets raised if timecode is out of range (like 100 hours long)
  class RangeError < Error; end

  # Gets raised when a timecode cannot be parsed
  class CannotParse < Error; end

  # Gets raised when you try to compute two timecodes with different framerates together
  class WrongFramerate < ArgumentError; end
  
  # Initialize a new Timecode object with a certain amount of frames and a framerate
  # will be interpreted as the total number of frames
  def initialize(total = 0, fps = DEFAULT_FPS)
    raise WrongFramerate, "FPS cannot be zero" if fps.zero?
    
    # If total is a string, use parse
    raise RangeError, "Timecode cannot be negative" if total.to_i < 0
    # Always cast framerate to float, and num of rames to integer
    @total, @fps = total.to_i, fps.to_f
    @value = validate!
    freeze
  end
  
  def inspect # :nodoc:
    "#<Timecode:%s (%dF@%.2f)>" % [to_s, total, fps]
  end
  
  class << self
    
    # Use initialize for integers and parsing for strings
    def new(from, fps = DEFAULT_FPS)
      from.is_a?(String) ? parse(from, fps) : super(from, fps)
    end
    
    # Parse timecode and return zero if none matched
    def soft_parse(input, with_fps = DEFAULT_FPS)
      parse(input) rescue new(0, with_fps)
    end
      
    # Parse timecode entered by the user. Will raise if the string cannot be parsed.
    # The following formats are supported:
    # * 10h 20m 10s 1f (or any combination thereof) - will be disassembled to hours, frames, seconds and so on automatically
    # * 123 - will be parsed as 00:00:01:23
    # * 00:00:00:00 - will be parsed as zero TC
    def parse(input, with_fps = DEFAULT_FPS)
      # Drop frame goodbye
      raise Error, "We do not support drop frame" if (input =~ /\;/)
      
      hrs, mins, secs, frames = 0,0,0,0
      atoms = []
      
      # 00:00:00:00
      if (input =~ COMPLETE_TC_RE)
        atoms = input.scan(COMPLETE_TC_RE).to_a.flatten
      # 00:00:00.0
      elsif input =~ FRACTIONAL_TC_RE
        parse_with_fractional_seconds(input, with_fps)
      # 10h 20m 10s 1f
      elsif input =~ /\s/
        return input.split.map{|part|  parse(part, with_fps) }.inject { |sum, p| sum + p.total }
      # 10s
      elsif input =~ /^(\d+)s$/
        return new(input.to_i * with_fps, with_fps)
      # 10h
      elsif input =~ /^(\d+)h$/i
        return new(input.to_i * 60 * 60 * with_fps, with_fps)
      # 20m
      elsif input =~ /^(\d+)m$/i
        return new(input.to_i * 60 * with_fps, with_fps)
      # 60f - 60 frames, or 2 seconds and 10 frames
      elsif input =~ /^(\d+)f$/i
        return new(input.to_i, with_fps)
      # A bunch of integers
      elsif (input =~ /^(\d+)$/)
        ints = input.split(//)
        atoms.unshift [ints.pop, ints.pop].reverse.join.to_i
        atoms.unshift [ints.pop, ints.pop].reverse.join.to_i
        atoms.unshift [ints.pop, ints.pop].reverse.join.to_i
        atoms.unshift [ints.pop, ints.pop].reverse.join.to_i
      else
        raise CannotParse, "Cannot parse #{input} into timecode, no match"
      end
      
      if atoms.any?
        hrs, mins, secs, frames = atoms.map{|e| e.to_i}
      else
        raise CannotParse, "Cannot parse #{input} into timecode, atoms were empty"
      end
      
      at(hrs, mins, secs, frames, with_fps)
    end
    
    # Initialize a Timecode object at this specfic timecode
    def at(hrs, mins, secs, frames, with_fps = DEFAULT_FPS)
      case true
        when hrs > 99
          raise RangeError, "There can be no more than 99 hours, got #{hrs}"
        when mins > 59
          raise RangeError, "There can be no more than 59 minutes, got #{mins}"
        when secs > 59
          raise RangeError, "There can be no more than 59 seconds, got #{secs}"
        when frames > (with_fps -1)
          raise RangeError, "There can be no more than #{with_fps -1} frames @#{with_fps}, got #{frames}"
      end
    
      total = (hrs*(60*60*with_fps) +  mins*(60*with_fps) + secs*with_fps + frames).round
      new(total, with_fps)
    end
    
    # Parse a timecode with fractional seconds instead of frames. This is how ffmpeg reports
    # a timecode
    def parse_with_fractional_seconds(tc_with_fractions_of_second, fps = DEFAULT_FPS)
      fraction_expr = /\.(\d+)$/
      fraction_part = ('.' + tc_with_fractions_of_second.scan(fraction_expr)[0][0]).to_f

      seconds_per_frame = 1.0 / fps.to_f
      frame_idx = (fraction_part / seconds_per_frame).floor

      tc_with_frameno = tc_with_fractions_of_second.gsub(fraction_expr, ":%02d" % frame_idx)

      parse(tc_with_frameno, fps)
    end
  
    # create a timecode from the number of seconds. This is how current time is supplied by
    # QuickTime and other systems which have non-frame-based timescales
    def from_seconds(seconds_float, the_fps = DEFAULT_FPS)
      total_frames = (seconds_float.to_f * the_fps.to_f).ceil
      new(total_frames, the_fps)
    end
  
    # Some systems (like SGIs) and DPX format store timecode as unsigned integer, bit-packed. This method
    # unpacks such an integer into a timecode.
    def from_uint(uint, fps = DEFAULT_FPS)
      tc_elements = (0..7).to_a.reverse.map do | multiplier | 
        ((uint >> (multiplier * 4)) & 0x0F)
      end.join.scan(/(\d{2})/).flatten.map{|e| e.to_i}

      tc_elements << fps
      at(*tc_elements)
    end
  end
  
  # is the timecode at 00:00:00:00
  def zero?
    @total.zero?
  end
  
  # get total frame count
  def total
    to_f
  end
  
  # get FPS
  def fps
    @fps
  end
    
  # get the number of frames
  def frames
    value_parts[3]
  end
  
  # get the number of seconds
  def seconds
    value_parts[2]
  end
  
  # get the number of minutes
  def minutes
    value_parts[1]
  end
  
  # get the number of hours
  def hours
    value_parts[0]
  end
  
  # get frame interval in fractions of a second
  def frame_interval
    1.0/@fps
  end
  
  # get the timecode as bit-packed unsigned 32 bit int (suitable for DPX and SGI)
  def to_uint
    elements = (("%02d" * 4) % [hours,minutes,seconds,frames]).split(//).map{|e| e.to_i }
    uint = 0
    elements.reverse.each_with_index do | p, i |
      uint |= p << 4 * i 
    end
    uint
  end
  
  # Convert to different framerate based on the total frames. Therefore,
  # 1 second of PAL video will convert to 25 frames of NTSC (this 
  # is suitable for PAL to film TC conversions and back).
  def convert(new_fps)
    self.class.new(@total, new_fps)
  end
  
  # get formatted SMPTE timecode
  def to_s
    WITH_FRAMES % value_parts
  end
  
  # get total frames as float
  def to_f
    @total
  end

  # get total frames as integer
  def to_i
    @total
  end
  
  # add number of frames (or another timecode) to this one
  def +(arg)
    if (arg.is_a?(Timecode) && framerate_in_delta(arg.fps, @fps))
      Timecode.new(@total+arg.total, @fps)
    elsif (arg.is_a?(Timecode))
      raise WrongFramerate, "You are calculating timecodes with different framerates"
    else
      Timecode.new(@total + arg, @fps)
    end
  end
  
  # Subtract a number of frames
  def -(arg)
    if (arg.is_a?(Timecode) &&  framerate_in_delta(arg.fps, @fps))
      Timecode.new(@total-arg.total, @fps)
    elsif (arg.is_a?(Timecode))
      raise WrongFramerate, "You are calculating timecodes with different framerates"
    else
      Timecode.new(@total-arg, @fps)
    end
  end
  
  # Multiply the timecode by a number
  def *(arg)
    raise RangeError, "Timecode multiplier cannot be negative" if (arg < 0)
    Timecode.new(@total*arg.to_i, @fps)
  end
  
  # Get the next frame
  def succ
    self.class.new(@total + 1, @fps)
  end
  
  # Get the number of times a passed timecode fits into this time span (if performed with Timecode) or 
  # a Timecode that multiplied by arg will give this one
  def /(arg)
    arg.is_a?(Timecode) ?  (@total / arg.total) : Timecode.new(@total /arg, @fps)
  end
  
  # Timecodes can be compared to each other
  def <=>(other_tc)
    if other_tc.is_a?(Timecode) && framerate_in_delta(fps, other_tc.fps)
      self.total <=> other_tc.total
    else
      self.total <=> other_tc
    end
  end
  
  # FFmpeg expects a fraction of a second as the last element instead of number of frames. Use this
  # method to get the timecode that adheres to that expectation. The return of this method can be fed
  # to ffmpeg directly.
  #  Timecode.parse("00:00:10:24", 25).with_frames_as_fraction #=> "00:00:10.96"
  def with_frames_as_fraction
    vp = value_parts.dup
    vp[-1] = (100.0 / @fps) * vp[-1]
    WITH_FRACTIONS_OF_SECOND % vp
  end
  alias_method :with_fractional_seconds, :with_frames_as_fraction
  
  # Validate that framerates are within a small delta deviation considerable for floats
  def framerate_in_delta(one, two)
    (one.to_f - two.to_f).abs <= ALLOWED_FPS_DELTA
  end
  
  private
  
  # Formats the actual timecode output from the number of frames
  def validate!
    frames = @total
    secs = (@total.to_f/@fps).floor
    frames-=(secs*@fps)
    mins = (secs/60).floor
    secs -= (mins*60)
    hrs = (mins/60).floor
    mins-= (hrs*60)
  
    raise RangeError, "Timecode cannot be longer that 99 hrs" if hrs > 99 
    raise RangeError, "More than 59 minutes" if mins > 59 
    raise RangeError, "More than 59 seconds" if secs > 59
    raise RangeError, "More than #{@fps.to_s} frames (#{frames}) in the last second" if frames >= @fps
  
    [hrs, mins, secs, frames]
  end
  
  def value_parts
    @value ||= validate!
  end
  
end