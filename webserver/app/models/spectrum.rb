class Spectrum < ActiveRecord::Base

	validates_presence_of :title, :on => :create, :message => "can't be blank"
	validates_presence_of :author, :on => :create, :message => "can't be blank"
	validates_presence_of :photo, :on => :create, :message => "can't be blank"
	validates_length_of :title, :maximum=>60
        validates_format_of :title, :with => /\A[a-zA-Z0-9\ -_]+\z/, :message => "Only letters, numbers, and spaces allowed" 
        validates_format_of :author, :with => /\A[a-zA-Z0-9_]+\z/, :message => "Only letters and numbers allowed" 

	has_many :comments, :dependent => :destroy
	has_many :tags, :dependent => :destroy
	
	# Paperclip
	has_attached_file :photo,
	  :styles => {
	    :thumb=> "300x100!",
	    :large =>   "800x200!" }

	has_attached_file :baseline,
	  :styles => {
	    :thumb=> "300x100!",
	    :large =>   "800x200!" }

  def before_save
    self.title.gsub('"',"'")
  end

  def after_save
    self.correct_reversed_image
  end

  def before_destroy
     self.sets.each do |set|
       ids = []
       spectra_ids = set.spectra_string.split(',').each do |id|
         ids << id if id.to_i != self.id
       end
       if ids.length > 0 
         set.spectra_string = ids.join(',')
         set.save
       else
         set.delete
       end
    end
  end

  # finds the brightest row of the image and uses that as its sample row
  def find_brightest_row
    require 'rubygems'
    require 'RMagick'
    pixels = []

    image   = Magick::ImageList.new("public"+(self.photo.url.split('?')[0]).gsub('%20',' '))
    rows = image.export_pixels(0, 0, image.columns, image.rows, "RGB");
    brightest_row = 0
    brightest = 0
    # sum brightness for each row
    (0..(image.rows-1)).each do |row|
      brightness = 0
      (0..(image.columns/3-1)).each do |col|
        r = rows[row*image.columns+col*3]
        g = rows[row*image.columns+col*3+1]
        b = rows[row*image.columns+col*3+2]
        brightness += (r-g).abs+(g-b).abs+(b-r).abs # difference between colors
        brightness += r+g+b # overall brightness
      end
      if brightness > brightest
        brightest_row = row 
        brightest = brightness
      end
    end
    brightest_row
  end

  def correct_reversed_image
    require 'rubygems'
    require 'RMagick'
    pixels = []

    image   = Magick::ImageList.new("public"+(self.photo.url.split('?')[0]).gsub('%20',' '))
    row = image.export_pixels(0, self.sample_row, image.columns, 1, "RGB");
    left_redness = 0
    right_redness = 0
    # sum redness for each half
    (0..(row.length/3-1)).each do |i|
      r = row[i*3]/255
      b = row[i*3+2]/255
      if i*3 > row.length/2
        left_redness += r
        left_redness -= b
      else
        right_redness += r
        right_redness -= b
      end
    end
    if left_redness < right_redness
      self.reverse
    end
  end

  # extracts serialized data from the top row of the stored image
  def extract_data
    require 'rubygems'
    require 'RMagick'
    pixels = []

    image   = Magick::ImageList.new("public"+(self.photo.url.split('?')[0]).gsub('%20',' '))
    row = image.export_pixels(0, self.sample_row, image.columns, 1, "RGB");

    (0..(row.length/3-1)).each do |p|
      r = row[p*3]/255
      g = row[p*3+1]/255
      b = row[p*3+2]/255
      pixels << '{wavelength:null,average:'+((r+g+b)/3).to_s+',r:'+r.to_s+',g:'+g.to_s+',b:'+b.to_s+'}'
    end

    # save it internally
    s = "{name:'"+self.title+"',lines: ["
    s += pixels.join(',')
    s += "]}"
    self.data = s
    s
  end

  # {wavelength:null,average:0,r:0,g:0,b:0}
  def scale_data(start_w,end_w)
    d = ActiveSupport::JSON.decode(self.data)
    i = 0 
    d['lines'].each do |line|
      line['wavelength'] = (start_w.to_f + i*((end_w.to_f-start_w.to_f)*1.00/d['lines'].length))
      i += 1
    end
    self.data = ActiveSupport::JSON.encode(d)
    self
  end

  def calibrated
    d = ActiveSupport::JSON.decode(self.data)
    !d['lines'].first['wavelength'].nil?
  end

  def calibrate(x1,wavelength1,x2,wavelength2)
    d = ActiveSupport::JSON.decode(self.data)
    i = 0 
    stepsize = ((wavelength2.to_f-wavelength1.to_f)*1.00/(x2.to_f-x1.to_f))
    startwavelength = wavelength1.to_f-(stepsize*x1.to_f)
    d['lines'].each do |line|
      line['wavelength'] = startwavelength + i*stepsize
      i += 1
    end
    self.reverse if (wavelength1 < wavelength2 && x1 > x2) || (wavelength1 > wavelength2 && x1 < x2)
    self.data = ActiveSupport::JSON.encode(d)
    self
  end

  # clones calibration from another spectrum (preferably taken from the same device)
  def clone(clone_id)
    clone_source = Spectrum.find clone_id 
    d = ActiveSupport::JSON.decode(self.data)
    cd = ActiveSupport::JSON.decode(clone_source.data)
    i = 0 
    # assume linear:
    stepsize = (cd['lines'][10]['wavelength'].to_f-cd['lines'][0]['wavelength'].to_f)/10.00
    d['lines'].each do |line|
      if cd['lines'][i]
        line['wavelength'] = cd['lines'][i]['wavelength'] 
      else
        line['wavelength'] = cd['lines'][0]['wavelength'].to_f+(i*stepsize)
      end
      i += 1
    end
    # figure out how to know when to reverse based on a cloned calibration... maybe we need to store reversal...
    #self.reverse if (wavelength1 < wavelength2 && x1 > x2) || (wavelength1 > wavelength2 && x1 < x2)
    self.data = ActiveSupport::JSON.encode(d)
    self.notes = self.notes.to_s+" -- (Cloned calibration from <a href='/spectra/show/"+clone_id.to_s+"'>"+clone_source.title+"</a>)"
    self
  end

  # rotate clockwise
  def rotate
    require 'rubygems'
    require 'RMagick'

    image   = Magick::ImageList.new("public"+(self.photo.url.split('?')[0]).gsub('%20',' '))
    image.rotate!(90)
    image.write("public"+self.photo.url)
    self.photo.reprocess!
  end

  # horizontally flips image to match reversed spectrum
  # this needs to re-save all the Paperclip versions too... it only works for the original image now
  def reverse
    require 'rubygems'
    require 'RMagick'

    image   = Magick::ImageList.new("public"+(self.photo.url.split('?')[0]).gsub('%20',' '))
    image.flop!
    image.write("public"+self.photo.url)
    self.photo.reprocess!
  end

  # this is embarassing 
  # someday rewrite with a join table
  def sets
    SpectraSet.find(:all, :conditions => ["spectra_string = '?' OR spectra_string LIKE '%,?,%' OR spectra_string LIKE '%,?' OR spectra_string LIKE '?,%'",self.id,self.id,self.id,self.id])
  end

  def image_from_dataurl(data)
    # remove image/png:base,
    data = data.split(',').pop

    # decode base64:
    data = Base64.decode64(data)

    self.photo = Paperclip::string_to_file('capture.png', 'image/png', data)
    self.save
  end

  def tags
    Tag.find_all_by_spectrum_id self.id
  end

  # a string of either a single tag name or a series of comma-delimited tags
  def tag(tags,user_id) 
    tags.split(',').each do |name|
      Tag.new({
        :spectrum_id => self.id,
        :name => name.strip,
        :user_id => user_id,
      }).save!
    end
  end


  def data_as_hash
    ActiveSupport::JSON.decode(self.data)['lines']
  end

  def bin_data(binsize)
    bins = {}
    count = {}

    self.data_as_hash.each do |datum|
      bin = (datum['wavelength'].to_f/binsize).to_i
      bins[bin] = 0 if bins[bin].nil?
      bins[bin] += datum['average'].to_i
      count[bin] = 0 if count[bin].nil?
      count[bin] += 1 
    end
    result = {}
    bins.each_with_index do |bin,i|
      bin[1] = bin[1]/count[i] if count[i].to_i > 0
      result[bin[0].to_i*binsize] = bin[1]
    end
    result
  end

  # compare self to other spectrum, return a # score
  def compare(spectrum_id)
    # both must be calibrated (do we need a flag for this?)

    # find difference, subtract average, square it
    # find overall average
    sum = 0
    data = self.bin_data(10)
    other = Spectrum.find(spectrum_id).bin_data(10)
    difference = 0
    difference_sum = 0
    data.each do |bin|
      sum += bin[1]
      difference_sum += 1
      difference += (other[bin[1]]-data[bin[1]])**2 unless (other[bin[1]].nil? || data[bin[1]].nil?)
    end
    average = sum/data.length

    # can we generate a "score" of the match? how close it was?
    difference
  end

  def find_match_in_set(set_id)
    set = sort_set(set_id)
    # find lowest score, return it
    set = set.sort_by {|a| a[1]}
    Spectrum.find set[0][0].to_i
  end

  def sort_set(set_id)
    set = SpectraSet.find set_id
    scored = {}

    set.spectra_string.split(',').each do |id|
      scored[id] = self.compare(id) if id.to_i != self.id
    end
    scored
  end

  def wavelength_range
    d = ActiveSupport::JSON.decode(self.data)
    [d['lines'][0]['wavelength'],d['lines'][d['lines'].length-1]['wavelength']]
  end

  # new spectrum from string of "wavelength:value,wavelength:value"
  def self.new_from_string(data)
    json = "{ 'lines': ["
    cols = data.split(',')
    cols.each_with_index do |datum,i|
      datum = datum.split(':')
      json += "{'wavelength':"+datum[0]+",'average':"+datum[1]+"}"
      json += "," if i < cols.length-1
    end
    json += "]}"
    self.new({:data => json})
  end

  def has_tag(name)
    !Tag.find_by_name(name,:conditions => {:spectrum_id => self.id}).nil?
  end

end
