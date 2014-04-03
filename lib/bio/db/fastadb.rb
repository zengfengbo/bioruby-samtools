#Module to hold the information about the fasta file

module Bio::DB::Fasta
  class Index
    include Enumerable
    attr_reader :entries
    
    def initialize
      @entries=[]
      @entries_map = Hash.new
    end
    
    #This doesnt validate if you are adding the same entry twice. I may add
    #a validation for that. 
    def << (entry)
      @entries << entry
      @entries_map[entry.id] = entry
    end
    
    def each(&block)
      @entries.entries(&block)
    end  
    
    def length
       @entries.length
    end
    
    #Returns a new Index just with the specified range, as if it was an Array. 
    #The return object is of type Index. 
    def [](args)
      tmp = @entries[args]
      new_index = Index.new
      tmp.each do | entry |
        @new_index << entry
      end       
    end
    
    def region_for_entry(entry)
       @entries_map[entry]
    end
  end
  
  class Entry
    attr_reader :id, :length
    
    def initialize(id, length)
      @id=id
      @length=length.to_i
    end
    
    def get_full_region
      reg = Region.new
      reg.entry = id
      reg.start = 0
      reg.end = @length
      reg.orientation = :forward
      reg
    end
    
    def to_region
      get_full_region
    end
  end
  
  #Class to wrap a region of a chromosome
  class Region
    BASE_COUNT_ZERO =  {:A => 0, :C => 0, :G => 0,  :T => 0}
    attr_accessor :entry, :start, :end, :orientation
    attr_accessor :pileup, :average_coverage, :snps, :reference, :base_ratios, :consensus, :coverages, :bases, :total_cov

    #TODO: Debug, as it hasnt been tested in the actual code. 
    def base_ratios_for_base(base)
      @all_ratios = Hash.new unless @all_ratios
      unless @all_ratios[base]
        ratios = Array.new
        for i in (0..region.size-1)
          ratios << @base_ratios[i][base]
        end
        @all_ratios[base] = ratios
      end
      @all_ratios[base]
    end
    
    def calculate_stats_from_pile(opts={})
      min_cov = opts[:min_cov] ? opts[:min_cov] : 0

      reference = self.reference.downcase
      
       self.base_ratios = Array.new(self.size, BASE_COUNT_ZERO) 
       self.bases = Array.new(self.size, BASE_COUNT_ZERO) 
       self.coverages = Array.new(self.size, 0)
       self.total_cov = 0

      self.pileup.each do | pile |
        
        if pile.coverage > min_cov
           self.base_ratios[pile.pos - self.start ] = pile.base_ratios
           reference[pile.pos - self.start   ] = pile.consensus_iuap(0.20).upcase
           self.coverages[pile.pos - self.start   ]  = pile.coverage.to_i
           self.bases[pile.pos - self.start       ]  = pile.bases
        end
        #puts "#{pile.pos}\t#{bef}\t#{reference[pile.pos - region.start  - 1 ]} "
         self.total_cov += pile.coverage
      end

      self.consensus = Bio::Sequence.new(reference)
      self.consensus.na
      if self.orientation == :reverse
        self.consensus.reverse_complement!()
      end
      self.average_coverage = self.total_cov.to_f/self.size.to_f
      self
    end
    
    def to_s
      string = @entry + ":" + @start.to_s + "-" + @end.to_s 
      string
    end
    
    def self.parse_region(reg_str)
        string = reg_str.delete("'")
        fields_1 = string.split(":")
        fields_2 = fields_1[1].split("-")
        raise FastaDBException.new(), "Invalid region. #{string}" if fields_1.length != 2 || fields_2.length != 2
        
        reg = Region.new
        reg.entry = fields_1[0]
        reg.start = fields_2[0].to_i
        reg.end = fields_2[1].to_i
        
        if reg.end < reg.start 
          reg.orientation = :reverse
        else
          reg.orientation = :forward
        end
        reg
    end
    
    def size
      @end - @start
    end
  
  end
  
  class FastaDBException < StandardError; end
  
  #Class that holds the fasta file. It is used as a database. It heavily relies ond samtools. 
  class FastaFile
    
    attr_reader :index, :fasta_path
    
    
    
    def initialize(args)
     @fasta_path = args[:fasta]
     @samtools = args[:samtools] || File.join(File.expand_path(File.dirname(__FILE__)),'sam','external','samtools')
      raise FastaDBException.new(), "No path for the refernce fasta file. " if @fasta_path.nil?
      @fai_file = @fasta_path + ".fai" 
      unless File.file?(@fai_file) then
        command = "#{@samtools} faidx '#{@fasta_path}'"
        @last_command = command
        system(command)
      end
     
    end
    
    def load_fai_entries()
      return  @index.length if @index
      @index = Index.new
      fai_file = @fai_file
      File.open(fai_file).each do | line |
        fields = line.split("\t")
        @index << Entry.new(fields[0], fields[1])
      end     
      @index.length
    end
    
   
    
    #Index reference sequence in the FASTA format or extract subsequence from indexed reference sequence. If no region is specified, faidx will index the file and create <ref.fasta>.fai on the disk. If regions are speficified, the subsequences will be retrieved and printed to stdout in the FASTA format.
    #Options - if a subsequence is required
    #* chr - [STRING] the reference name of the subsequence
    #* start - [INT] the start position for the subsequence
    #* stop - [INT] the stop position for the subsequence
    def faidx(opts={})
      if opts.has_key?(:chr) and opts.has_key?(:start) and opts.has_key?(:stop)
      opts={:as_bio => false}
      self.fetch_reference(:chr,:start,:stop,opts)
      else
        command = "#{@samtools} faidx #{@fasta_path}"
        @last_command = command
        system(command)
      end
    end
    
    
    #The region needs to have a method to_region or a method to_s that ha the format "chromosome:start-end" as in samtools
    def fetch_sequence(region)
      
        
        query = region.to_s
        query = region.to_region.to_s if region.respond_to?(:to_region) 
        command = "#{@samtools} faidx #{@fasta_path} '#{query}'"
        puts command
        @last_command = command
        seq = ""
        yield_from_pipe(command, String, :text ) {|line| seq = seq + line unless line =~ /^>/}
       
        reference = Bio::Sequence::NA.new(seq)
        
        if region.orientation == :reverse
          #puts "reversing! #{reference.to_s}"
          reference.reverse_complement!()
        end
        reference
    end
    
    def yield_from_pipe(command, klass, type=:text, skip_comments=true, comment_char="#", &block)
      pipe = IO.popen(command)
      if type == :text
        while (line = pipe.gets)
          next if skip_comments and line[0] == comment_char
          yield klass.new(line.chomp)
        end
      elsif type == :binary
        while (c = pipe.gets(nil))
          yield c
        end
      end
      pipe.close
    end
     
  end
end
