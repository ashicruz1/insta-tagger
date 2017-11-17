require "open-uri"
require "nokogiri"
require "pry"

url = "https://top-hashtags.com/instagram/"

1.step(1_000_000, 100).each do |page|
  puts page

  doc = Nokogiri::HTML(open("#{url}#{page}").read)

  rows = doc.css("li > .row").select { |r| r.children.size == 4 }.map do |row|
    tag, count = row.children.map(&:text)[1..2].map(&:strip)

    count_number = count.scan(/[0-9\.]+/).first.to_f

    case count[-1]
    when "B"
      count = count_number * 1_000_000_000
    when "M"
      count = count_number * 1_000_000
    when "K"
      count = count_number * 1_000
    else
      next
    end

    [tag, count.to_i].join(",")
  end

  File.open("top_tags.txt", "a") { |f|
    f.write rows.join("\n") + "\n"
  }
end
