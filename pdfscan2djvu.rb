#!/usr/bin/env ruby

VERSION = 0.1

# pdfscan2djvu - Convert PDF files with scanned book pages to DjVu
#
# Written in 2024 by Siarhei Siamashka <siarhei.siamashka@gmail.com>
#
# To the extent possible under law, the author(s) have dedicated all copyright
# and related and neighboring rights to this software to the public domain
# worldwide. This software is distributed without any warranty.
#
# You should have received a copy of the CC0 Public Domain Dedication along with
# this software. If not, see http://creativecommons.org/publicdomain/zero/1.0/

require "shellwords"
require "base64"
require "digest"
require "tempfile"

# See 'man c44' or https://linux.die.net/man/1/c44
# The 'mediocre'/'average'/'good' presets are the settings
# mentioned in the man page ('average' is the c44 default).
# But this conversion script aims better quality for its
# own default. There's also an extra 'superb' preset,
# which roughly matches the sizes of some PDFs with
# JPEG2000 images from polona.pl
quality_presets = { "bad" => "74,86,95",
                    "mediocre" => "74,87,97",
                    "average" => "74,89,99",
                    "good" => "72,83,93,103",
                    "superb" => "74,89,99,111" }
quality = quality_presets["good"]

# Other settings
keep_jpegs = "auto"
keep_jpegs_threshold = 0.75
to_delete = {}
to_insert = {}

# Handle the command line arguments. This part doesn't need any
# extra explanations.

args = ARGV.filter do |arg|
  if arg =~ /^\-d(elete)?\=([x\d\,]+)$/
    $2.split(",").map do |entry|
      if entry =~ /^(\d+)(x(\d+))?$/
        start, cnt = $1.to_i, ($3 || 1).to_i
        abort "Invalid page number #{start} in '#{arg}'." if start < 1
        start.upto(start + cnt - 1) { |idx| to_delete[idx] = [arg] }
      else
        abort "Unrecognized command line option: '#{arg}'\n"
      end
    end
    nil
  elsif arg =~ /^\-i(nsert)?\=(\d+)(x(\d+))?(\:(.*))?$/
    start, cnt, fname = $2.to_i, ($4 || 1).to_i, $6
    if cnt > 0
      abort "Invalid page number #{start} in '#{arg}'." if start < 1
      abort "File not found: '#{fname}'\n" if fname && !File.exists?(fname)
      to_insert[start] = [] unless to_insert.has_key?(start)
      to_insert[start].push([arg, cnt, fname])
    end
    nil
  elsif arg =~ /^\-q(uality)?\=(.*)$/
    quality = $2
    unless quality =~ /^[\d\,\+]+$/ && quality =~ /^\d/ && quality =~ /\d$/
      if quality_presets.has_key?(quality)
        quality = quality_presets[quality]
      else
        abort "Unrecognized command line option: '#{arg}'\n"
      end
    end
    nil
  elsif arg =~ /^\-j(pegs?)?(\=(auto(\:(0\.\d+))?|never|always))?$/
    if $5
      keep_jpegs = "auto"
      keep_jpegs_threshold = $5.to_f
    else
      keep_jpegs = $3
    end
    nil
  elsif arg =~ /^[\-\+]/
    abort "Unrecognized command line option: '#{arg}'\n"
  else
    arg
  end
end

unless args[0] && args[0] =~ /\.pdf$/i && File.exists?(args[0])
  puts "pdfscan2djvu v#{VERSION} - interpret PDF as just a container of images (ignoring"
  puts "                    everything else in it) and convert to DjVu."
  puts
  puts "Usage: ruby pdfscan2djvu.rb [options] <input.pdf> [output.djvu]"
  puts "Where options can be:"
  puts "  -q[uality]=             : a line for the c44 tool's -slice option or one"
  puts "                            of the #{quality_presets.keys.join("/")} presets."
  puts "                            The default is 'good' (#{quality_presets["good"]})."
  puts
  puts "  -j[pegs]=[never|        : optionally take the original JPG images from the"
  puts "            always|         PDF file and transplant them to the generated"
  puts "            auto[:frac]]    DjVu file as-is without recompressing."
  puts "                            This is useful when the original JPGs are low"
  puts "                            resolution and/or already heavily compressed, so"
  puts "                            degrading them further is highly undesirable."
  puts "                            The possible choices are 'never', 'always' and"
  puts "                            'auto'. The default is 'auto', which evaluates"
  puts "                            each JPG image independently and automatically"
  puts "                            keeps it as-is if the size reduction offered"
  puts "                            by the c44 recompression isn't significant"
  puts "                            enough (the default threshold is #{keep_jpegs_threshold})."
  puts
  puts "  -d[elete]=n             : remove the n-th page (n is a decimal number)."
  puts "                            Page numbers are tied to the original PDF."
  puts "                            Multiple pages can be provided as a comma"
  puts "                            separated list. E.g. something like '-d=3,141,9'."
  puts
  puts "  -i[nsert]=n[:image.jpg] : insert a new page before the n-th page. If the"
  puts "                            desired file name is not provided as an optional"
  puts "                            argument, then a special placeholder notice will"
  puts "                            be inserted."
  puts
  puts "Example of removing the 3rd page and inserting another image before the 5th:"
  puts "    ruby pdfscan2djvu.rb -d=3 -i=5:image.djvu book.pdf book.djvu"
  exit 0
end

inputfile = args[0]
outputfile = args[1] || args[0].gsub(/\.pdf$/i, ".djvu")
outputfile += ".djvu" unless outputfile =~ /\.djvu$/i

def parse_pdf_info(filename)
  data = `pdfimages -list #{Shellwords.escape(filename)}`
  fail unless $?.exitstatus == 0

  # Valid output example:
  # page   num  type   width height color comp bpc  enc interp  object ID x-ppi y-ppi size ratio
  # --------------------------------------------------------------------------------------------
  #    1     0 image    1065  1543  rgb     3   8  jpeg   no       849  0   200   200  156K 3.2%
  good = false
  images = {}
  data.each_line do |l|
    next if l =~ /^\s*\-/
    if good
      a = l.split
      pdfpage = a[0].to_i
      imgnum = a[1].to_i
      return nil, "unexpected image type" unless a[2] == "image"
      w = a[3].to_i
      h = a[4].to_i
      color = a[5]
      xdpi = a[12].to_i
      ydpi = a[13].to_i
      return nil, "unexpected dpi" unless xdpi == ydpi && xdpi > 0
      return nil, "more than one image on a single page #{pdfpage}" if images.has_key?(pdfpage)
      color = "mono" if a[6].to_i == 1 && a[7].to_i == 1
      encformat = a[8]
      images[pdfpage] = { color: color, w: w, h: h, dpi: xdpi, enc: encformat }
    end
    good = true if l =~ /^\s*page\s+num\s+type\s+width\s+height\s+color\s+comp\s+bpc\s+enc\s+interp\s+object\s+ID\s+x\-ppi\s+y\-ppi\s+size\s+ratio\s*$/
  end
  images_a = images.to_a.sort { |a, b| a[0] <=> b[0] }
  return nil, "no images found" unless images_a.size > 0
  return nil, "not every page has an image" unless images_a[0][0] == 1 && images_a[-1][0] == images.size
  return images_a, nil
end

printf("Inspecting images in '%s'. Please wait...", inputfile)
data, err = parse_pdf_info(inputfile)
abort " FAIL.\nThe input file '#{inputfile}' can't be converted: #{err}.\n" if err
puts " done.\n"
printf("File information: %d pages. Average page size: %dx%d pixels.\n",
       data.size, data.map { |x| x[1][:w] }.sum / data.size,
       data.map { |x| x[1][:h] }.sum / data.size)
printf("Quality settings for c44 transcoding: '-slice %s'.\n", quality)

# This is a base64 encoding of tiny DjVu file, containing the placeholder image
placeholder_img = Base64.decode64("
QVQmVEZPUk0AAAB4REpWVUlORk8AAAAKAdgBYBgAZAAWAVNqYnoAAABagEm3
8jpegtEVy/X6afXF3nZqMaNrAfnToZdSuOjLitvnAQRd5WwyTWHA7lRT4x4X
ILLYddSZ+E8NNCJ9eKAnQul8og195P0TSHbMAg6AKWfh6AI82UICBP8x")

Dir.mktmpdir { |tmpdir|
  tmp_prefix = File.join(tmpdir, "_")
  tmp_djvu = tmp_prefix + ".djvu"
  tmp_jpg = tmp_prefix + "-000.jpg"
  tmp_ppm = tmp_prefix + "-000.ppm"
  tmp_pbm = tmp_prefix + "-000.pbm"
  tmp_txt = tmp_prefix + ".txt"

  puts "Legend: c - lossy colored c44, g - lossy grayscale c44, b - lossless B&W cjb2,"
  puts "        J - transplanted original JPG, '-' - page deletion, '+' - page addition."
  printf "Progress:"

  pdf_page_num = 0
  out_page_num = 0
  data.each do |page|
    printf("\n%5d: ", pdf_page_num) if ((pdf_page_num += 1) % 10 == 1)
    if to_insert.has_key?(pdf_page_num)
      to_insert[pdf_page_num].each do |insert|
        cnt = insert[1]
        fname = insert[2]
        if not fname
          File.binwrite(tmp_djvu, placeholder_img)
          fname = tmp_djvu
        elsif fname =~ /\.jpg$/i
          img_inches = []
          if data[pdf_page_num - 2]
            img_inches.push(data[pdf_page_num - 2][1][:w].to_f / data[pdf_page_num - 2][1][:dpi])
          end
          if data[pdf_page_num - 1]
            img_inches.push(data[pdf_page_num - 1][1][:w].to_f / data[pdf_page_num - 1][1][:dpi])
          end
          `c44 -slice #{quality} #{Shellwords.escape(fname)} #{Shellwords.escape(tmp_djvu)}`
          fail unless $?.exitstatus == 0
          djvudump_output = `djvudump #{Shellwords.escape(tmp_djvu)}`
          abort "fdf" unless djvudump_output =~ /DjVu\s+(\d+)x(\d+)/
          w, h = $1.to_i, $2.to_i
          dpi = (w.to_f / (img_inches.sum / img_inches.size)).to_i
          `djvumake #{Shellwords.escape(tmp_djvu)} INFO=#{w},#{h},#{dpi} BGjp=#{Shellwords.escape(fname)}`
          fname = tmp_djvu
        end
        cnt.times do
          `djvm #{(out_page_num += 1) == 1 ? "-c" : "-i"} #{Shellwords.escape(outputfile)} #{Shellwords.escape(fname)}`
          fail unless $?.exitstatus == 0
          printf("+")
        end
      end
    end
    if to_delete.has_key?(pdf_page_num)
      printf("-")
      next
    end

    `pdfimages -f #{page[0]} -l #{page[0]} #{Shellwords.escape(inputfile)} #{Shellwords.escape(tmp_prefix)}`
    fail unless $?.exitstatus == 0
    if page[1][:enc] == "jpeg" && keep_jpegs != "never"
      `pdfimages -j -f #{page[0]} -l #{page[0]} #{Shellwords.escape(inputfile)} #{Shellwords.escape(tmp_prefix)}`
      fail unless $?.exitstatus == 0
    end

    progress_icon = "c"
    if page[1][:color] == "mono"
      `cjb2 -dpi #{page[1][:dpi]} #{Shellwords.escape(tmp_pbm)} #{Shellwords.escape(tmp_djvu)}`
      fail unless $?.exitstatus == 0
      progress_icon = "b"
      File.delete(tmp_pbm)
    else
      extraopt = ""
      if (page[1][:color] == "gray")
        progress_icon = "g"
        extraopt = "-crcbnone"
      end
      `c44 -dpi #{page[1][:dpi]} -slice #{quality} #{extraopt} #{Shellwords.escape(tmp_ppm)} #{Shellwords.escape(tmp_djvu)}`
      fail unless $?.exitstatus == 0
      if page[1][:enc] == "jpeg" && File.exists?(tmp_jpg)
        # Automatically keep JPG if we are not winning much in terms of file size.
        # Also keep all JPEGs if we were explicitly asked to do that.
        if (keep_jpegs == "auto" && File.size(tmp_jpg) * keep_jpegs_threshold < File.size(tmp_djvu)) || keep_jpegs == "always"
          w, h, dpi = page[1][:w], page[1][:h], page[1][:dpi]
          `djvumake #{Shellwords.escape(tmp_djvu)} INFO=#{w},#{h},#{dpi} BGjp=#{Shellwords.escape(tmp_jpg)}`
          fail unless $?.exitstatus == 0
          progress_icon = "J"
        end
        File.delete(tmp_jpg)
      end
      File.delete(tmp_ppm)
    end
    `djvm #{(out_page_num += 1) == 1 ? "-c" : "-i"} #{Shellwords.escape(outputfile)} #{Shellwords.escape(tmp_djvu)}`
    fail unless $?.exitstatus == 0
    File.delete(tmp_djvu)
    printf("%c", progress_icon)
  end
  inputsize = File.size(inputfile)
  outsize = File.size(outputfile)
  summary = (outsize < inputsize) ?
    sprintf("(x%.2f reduction)", inputsize.to_f / outsize) :
    sprintf("(x%.2f increase)", outsize.to_f / inputsize)
  puts "\nSummary:"
  puts "    PDF size: #{inputsize}, DjVu size: #{outsize} #{summary}."
  puts "    '#{outputfile}' is ready (#{out_page_num} pages)."

  # Add metadata to the created file

  # See 'man djvused'
  def djvused_str(s)
    subst = { "\t" => "\\t", "\n" => "\\n", "\r" => "\\r", "\"" => "\\\"", "\\" => "\\\\" }
    '"' + s.chars.map { |c| subst[c] || (c.ord < 0x20 ? sprintf("\\%o", c.ord) : c) }.join + '"'
  end

  def file_sha256(filename)
    h = Digest::SHA256.new
    File.open(filename, "rb") { |f| while buf = f.read(1024 * 1024) do h << buf end }
    h.hexdigest
  end

  djvused_txt = "set-meta; "
  djvused_txt << "Producer \"pdfscan2djvu v#{VERSION} (https://github.com/ssvb/pdfscan2djvu)\"\n"
  djvused_txt << "pdfscan2djvu_pdf_name #{djvused_str(File.basename(inputfile))}\n"
  djvused_txt << "pdfscan2djvu_pdf_sha256 #{file_sha256(inputfile)}\n"
  optnum = 0
  ARGV.filter { |arg| arg =~ /^\-/ }.each do |arg|
    djvused_txt << "pdfscan2djvu_opt#{optnum += 1} #{djvused_str(arg)}\n"
  end
  File.write(tmp_txt, djvused_txt)
  `djvused -s #{Shellwords.escape(outputfile)} -f #{Shellwords.escape(tmp_txt)}`
}
