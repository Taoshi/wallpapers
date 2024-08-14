#!/usr/bin/env ruby

require 'bundler/setup'
Bundler.require(:default)

class SmashingDownloader
  BASE_URL = 'https://www.smashingmagazine.com/'

  def initialize
    @options = parse_options
    @month = @options[:month][0..1]
    @year = @options[:month][2..5]
    @theme = @options[:theme].downcase
    @prev_month, @prev_year = calculate_previous_month_year
    @url = construct_url
    @client = OpenAI::Client.new(access_token: ENV.fetch('OPENAI_ACCESS_TOKEN', nil))
  end

  def download_wallpapers
    page = fetch_page
    theme_links = filter_links_by_theme(page)
    if theme_links.empty?
      puts "No links found for the theme '#{@theme}' in the month '#{@month}#{@year}'."
      return
    end
    create_directories
    progressbar = progress_bar(theme_links.size)
    Parallel.each(theme_links, in_threads: 10) do |link|
      next if link.nil?
      process_link(link, progressbar)
    end
  end

  private

  def progress_bar(size)
    ProgressBar.create(title: 'Downloading', total: size, format: '%t: |%B| %p%% %e')
  end

  def parse_options(args = ARGV, testing = false)
    options = {}
    OptionParser.new do |opts|
      opts.banner = 'Usage: smashing.rb --month MONTH --theme THEME'

      opts.on('--month MONTH', 'Specify the month in MMYYYY format') do |m|
        options[:month] = m
      end

      opts.on('--theme THEME', 'Specify the theme to search for') do |t|
        options[:theme] = t.downcase
      end
    end.parse!(args)

    if options[:month].nil? || options[:theme].nil?
      puts 'Both --month and --theme parameters are required.'
      exit
    end

    options
  end

  def calculate_previous_month_year
    prev_month = (@month.to_i - 1).to_s.rjust(2, '0')
    prev_year = @year

    if prev_month == '00'
      prev_month = '12'
      prev_year = (@year.to_i - 1).to_s
    end

    [prev_month, prev_year]
  end

  def construct_url
    "#{BASE_URL}#{@prev_year}/#{@prev_month}/desktop-wallpaper-calendars-#{Date::MONTHNAMES[@month.to_i].downcase}-#{@year}/"
  end

  def fetch_page
    uri = URI.parse(@url)
    response = Net::HTTP.get(uri)
    Nokogiri::HTML(response)
  rescue OpenURI::HTTPError => e
    puts "Failed to retrieve the webpage: #{e.message}"
    exit
  end

  def filter_links_by_theme(page)
    page.css('.article__content a').select do |link|
      link.text.strip.downcase.include?('smashingmagazine') ||
        link['title'].to_s.downcase.include?('smashingmagazine') ||
        link['href'].to_s.downcase.include?('smashingmagazine')
    end
  end

  def create_directories
    @base_output_dir = "#{Dir.pwd}/wallpapers/#{@month}#{@year}/#{@theme}"
    @calendar_dir = File.join(@base_output_dir, 'calendar')
    @no_calendar_dir = File.join(@base_output_dir, 'no-calendar')

    FileUtils.mkdir_p(@calendar_dir)
    FileUtils.mkdir_p(@no_calendar_dir)
  end

  def process_link(link, progressbar)
    href = link['href'].to_s
    has_calendar = href.include?('nocal') ? 'no-calendar' : 'calendar'
    response = gpt_response(href)

    if response.dig('choices', 0, 'message', 'content').downcase.include?('yes')
      output_dir = has_calendar == 'calendar' ? @calendar_dir : @no_calendar_dir
      file_name = File.join(output_dir, File.basename(URI.parse(href).path))

      download_file(href, file_name)
    else
      puts "Skipping: #{href} - Not related to theme #{@theme}"
    end

    progressbar.increment
  end

  def gpt_response(href)
    prompt = "Does this link '#{href}' contain an image related to '#{@theme}' simply yes or no?"
    raise 'OPENAI_ACCESS_TOKEN needed' if ENV['OPENAI_ACCESS_TOKEN'].nil?
    @client.chat(
      parameters: {
        model: 'gpt-4-turbo',
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 100
      }
    )
  end

  def download_file(href, file_name)
    Down.download(href, destination: file_name)
    puts "Downloaded to #{file_name}"
  rescue StandardError => e
    puts "Failed to download #{href}: #{e.message}"
  end
end

# Instantiate and run the wallpaper downloader
downloader = SmashingDownloader.new
downloader.download_wallpapers
