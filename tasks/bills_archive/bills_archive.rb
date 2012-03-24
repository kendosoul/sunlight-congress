require 'nokogiri'

class BillsArchive
  
  # options:
  #   session: The session of Congress to update
  def self.run(options = {})
    if !options[:only] or (options[:only] == "bills")
      bill_metadata! options
    end

    if !options[:only] or (options[:only] == "passage_votes")
      sort_passage_votes! options
    end
  end

  def self.sort_passage_votes!(options = {})
    session = options[:session] ? options[:session].to_i : Utils.current_session
    
    roll_count = 0
    voice_count = 0
    bad_votes = []
    
    missing_rolls = []
    
    bills = Bill.where(:session => session, :passage_votes_count => {"$gte" => 1}).all
    
    if options[:limit]
      bills = bills.to_a.first options[:limit].to_i
    end
    
    bills.each do |bill|
      
      # clear out old voice votes for this bill, since there is no unique ID to update them by
      Vote.where(:bill_id => bill.bill_id, :how => {"$ne" => "roll"}).all.each {|v| v.delete}
      
      bill.passage_votes.each do |vote|
        if vote['how'] == 'roll'
          
          # if the roll has been entered into the system already, mark it as a passage vote
          # otherwise, don't bother creating it here, we don't have enough information
          roll = Vote.where(:roll_id => vote['roll_id']).first
          
          if roll
            roll[:vote_type] = "passage"
            roll[:passage_type] = vote['passage_type']
            roll.save!
            
            roll_count += 1
            # puts "[#{bill.bill_id}] Updated roll call #{roll.roll_id} to mark as a passage vote"
          else
            missing_rolls << {:bill_id => bill.bill_id, :roll_id => vote['roll_id']}
            puts "[#{bill.bill_id}] Couldn't find roll call #{vote['roll_id']}, which was mentioned in passage votes list for #{bill.bill_id}"
          end
        else
          
          attributes = {
            :bill_id => bill.bill_id,
            :session => session,
            :year => vote['voted_at'].year,
            
            :bill => Utils.bill_for(bill.bill_id), # reusing the method standardizes on columns, worth the extra call
            
            :how => vote['how'],
            :result => vote['result'],
            :voted_at => vote['voted_at'],
            :question => question_for(bill),
            :chamber => vote['chamber'],
            
            :passage_type => vote['passage_type'],
            :vote_type => "passage"
          }
          
          vote = Vote.new attributes
          
          if vote.save
            voice_count += 1
            # puts "[#{bill.bill_id}] Added a voice vote"
          else
            bad_votes << {:attributes => attributes, :error_messages => vote.errors.full_messages}
            puts "[#{bill.bill_id}] Bad voice vote, logging"
          end
        end
      end
    end
    
    if bad_votes.any?
      Report.failure self, "Failed to save #{bad_votes.size} voice votes. Attached the last failed vote's attributes and error messages.", bad_votes.last
    end
    
    if missing_rolls.any?
      Report.warning self, "Found #{missing_rolls.size} roll calls mentioned in a passage votes array whose corresponding Vote object was not found", :missing_rolls => missing_rolls
    end
    
    Report.success self, "Updated #{roll_count} roll call and #{voice_count} voice passage votes"
  end

  def self.bill_metadata!(options = {})
    session = options[:session] ? options[:session].to_i : Utils.current_session
    count = 0
    missing_ids = []
    missing_from_govtrack = []
    missing_committees = []
    bad_bills = []
    
    unless options[:skip_sync]
      FileUtils.mkdir_p "data/govtrack/#{session}/bills"
      puts "Syncing bills from GovTrack for #{session}..." if options[:debug]
      unless system("rsync -az govtrack.us::govtrackdata/us/#{session}/bills/ data/govtrack/#{session}/bills/")
        Report.failure self, "Couldn't rsync to Govtrack.us for bills."
        return
      end
      
      puts "Syncing committees from GovTrack..." if options[:debug]
      unless system("rsync -az govtrack.us::govtrackdata/us/committees.xml data/govtrack/committees.xml")
        Report.failure self, "Couldn't rsync to Govtrack.us for committees.xml."
        return
      end

      # can be taken out if we decide to depend wholly again on the Sunlight API
      puts "Syncing people from GovTrack for #{session}..." if options[:debug]
      unless system("rsync -az govtrack.us::govtrackdata/us/#{session}/people.xml data/govtrack/#{session}/people.xml")
        Report.failure self, "Couldn't rsync to GovTrack.us for people.xml."
        return
      end
    end

    return if options[:only_sync]
    
    
    # legislator cache
    legislators = {}
    Legislator.only(Utils.legislator_fields).all.each do |legislator|
      legislators[legislator.govtrack_id] = Utils.legislator_for legislator
    end

    # old legislator cache
    doc = Nokogiri::XML open("data/govtrack/#{session}/people.xml")
    old_legislators = old_legislators_for doc
    
    cached_committees = cached_committees_for session, Nokogiri::XML(open("data/govtrack/committees.xml"))
    
    bills = Dir.glob "data/govtrack/#{session}/bills/*.xml"
    
    # debug helpers
    if options[:limit]
      bills = bills.first options[:limit].to_i
    elsif options[:bill_id]
      type, number, session, code, chamber = Utils.bill_fields_from options[:bill_id]
      govtrack_type = Utils.govtrack_type_for type
      bills = Dir.glob "data/govtrack/#{session}/bills/#{govtrack_type}#{number}.xml"
    end
    
    bills.each do |path|
      doc = Nokogiri::XML open(path)
      
      filename = File.basename path
      type = Utils.bill_type_for doc.root['type']
      number = doc.root['number'].to_i
      code = "#{type}#{number}"
      
      bill_id = "#{code}-#{session}"
      
      bill = Bill.find_or_initialize_by :bill_id => bill_id
      
      sponsor = sponsor_for filename, doc, legislators, missing_ids, old_legislators, missing_from_govtrack
      sponsor_id = sponsor ? sponsor['bioguide_id'] : nil

      cosponsors = cosponsors_for filename, doc, legislators, missing_ids
      committees = committees_for filename, doc, cached_committees, missing_committees
      related_bills = related_bills_for doc
      
      actions = actions_for doc
      titles = titles_for doc
      state = state_for doc
      passage_votes = passage_votes_for doc
      last_passage_vote_at = passage_votes.last ? passage_votes.last[:voted_at] : nil
      introduced_at = Utils.govtrack_time_for doc.at(:introduced)['datetime']
      
      last_action = last_action_for actions
      
      bill.attributes = {
        :bill_type => type,
        :number => number,
        :code => code,
        :session => session,
        :chamber => {'h' => 'house', 's' => 'senate'}[type.first.downcase],
        :state => state,
        :short_title => most_recent_title_from(titles, :short),
        :official_title => most_recent_title_from(titles, :official),
        :popular_title => most_recent_title_from(titles, :popular),
        :titles => titles,
        :summary => summary_for(doc),
        :sponsor => sponsor,
        :sponsor_id => sponsor_id,
        :cosponsors => cosponsors,
        :cosponsor_ids => cosponsors.map {|c| c['bioguide_id']},
        :cosponsors_count => cosponsors.size,
        :actions => actions,
        :last_action => last_action,
        :last_action_at => last_action ? last_action[:acted_at] : nil,
        :passage_votes => passage_votes,
        :passage_votes_count => passage_votes.size,
        :last_passage_vote_at => last_passage_vote_at,
        :introduced_at => introduced_at,
        :keywords => keywords_for(doc),
        :committees => committees,
        :related_bills => related_bills,
        :abbreviated => false
      }
      
      bill.attributes = timeline_for doc, state, passage_votes
      
      if bill.save
        count += 1
        puts "[#{bill_id}] Saved successfully" if options[:debug]
      else
        bad_bills << {:attributes => bill.attributes, :error_messages => bill.errors.full_messages}
        puts "[#{bill_id}] Error saving, will file report"
      end
    end

    if missing_from_govtrack.any?
      missing_from_govtrack = missing_from_govtrack.uniq
      Report.warning self, "Found #{missing_from_govtrack.size} missing people in people.xml, attached.", {:missing_from_govtrack => missing_from_govtrack}
    end
    
    if missing_ids.any?
      missing_ids = missing_ids.uniq
      Report.warning self, "Found #{missing_ids.size} missing GovTrack IDs, attached.", {:missing_ids => missing_ids}
    end
    
    if missing_committees.any?
      missing_committees = missing_committees.uniq
      Report.warning self, "Found #{missing_committees.size} missing committee IDs or subcommittee names, attached.", {:missing_committees => missing_committees}
    end
    
    if bad_bills.any?
      Report.failure self, "Failed to save #{bad_bills.size} bills. Attached the last failed bill's attributes and errors.", :bill => bad_bills.last
    end
    
    Report.success self, "Synced #{count} bills for session ##{session} from GovTrack.us."
  end
  
  
  def self.state_for(doc)
    doc.at(:state) ? doc.at(:state).text : "UNKNOWN"
  end
  
  def self.summary_for(doc)
    summary = doc.at(:summary).text.strip
    summary.present? ? summary : nil
  end
  
  def self.sponsor_for(filename, doc, legislators, missing_ids, old_legislators, missing_from_govtrack)
    sponsor = doc.at :sponsor
    if sponsor and sponsor['id'] and !sponsor['withdrawn']
      if legislators[sponsor['id']]
        legislators[sponsor['id']]
      else 
        missing_ids << [sponsor['id'], filename]

        if old_legislators[sponsor['id']]
          # {'bioguide_id' => old_legislators[sponsor['id']]}
        else
          missing_from_govtrack << sponsor['id']
          # nil
        end

        nil # remove if we use the old legislator cache someday

      end
    end
  end
  
  def self.cosponsors_for(filename, doc, legislators, missing_ids)
    cosponsors = []
    
    (doc/:cosponsor).each do |cosponsor| 
      if cosponsor and cosponsor['id'] and !cosponsor['withdrawn']
        if legislators[cosponsor['id']]
          cosponsors << legislators[cosponsor['id']]
        else
          missing_ids << [cosponsor['id'], filename]

          # if old_legislators[cosponsor['id']]
          #   cosponsors << {'bioguide_id' => old_legislators[cosponsor['id']]}
          # else
          #   missing_from_govtrack << cosponsor['id']
          # end

        end
      end
    end
    
    cosponsors
  end
  
  def self.titles_for(doc)
    # important that the result be an array so that we preserve order of titles
    # to pick out the most recent title later
    titles = doc.search "//title"
    titles.map do |title|
      {
        :type => title['type'],
        :as => title['as'],
        :title => title.inner_text
      }
    end
  end
  
  # prepare the full timeline of a bill, lots-of-flags style
  def self.timeline_for(doc, state, votes)
    timeline = {}
    
    if house_vote = votes.select {|vote| vote[:chamber] == 'house' and vote[:passage_type] != 'override'}.last
      timeline[:house_passage_result] = house_vote[:result]
      timeline[:house_passage_result_at] = house_vote[:voted_at]
    end
    
    if senate_vote = votes.select {|vote| vote[:chamber] == 'senate' and vote[:passage_type] != 'override'}.last
      timeline[:senate_passage_result] = senate_vote[:result]
      timeline[:senate_passage_result_at] = senate_vote[:voted_at]
    end
    
    if vetoed_action = doc.at('//actions/vetoed')
      timeline[:vetoed_at] = Utils.govtrack_time_for vetoed_action['datetime']
      timeline[:vetoed] = true
    else
      timeline[:vetoed] = false
    end
    
    if override_house_vote = votes.select {|vote| vote[:chamber] == 'house' and vote[:passage_type] == 'override'}.last
      timeline[:house_override_result] = override_house_vote[:result]
      timeline[:house_override_result_at] = override_house_vote[:voted_at]
    end
    
    if override_senate_vote = votes.select {|vote| vote[:chamber] == 'senate' and vote[:passage_type] == 'override'}.last
      timeline[:senate_override_result] = override_senate_vote[:result]
      timeline[:senate_override_result_at] = override_senate_vote[:voted_at]
    end
    
    if enacted_action = doc.at('//actions/enacted')
      timeline[:enacted_at] = Utils.govtrack_time_for enacted_action['datetime']
      timeline[:enacted] = true
    else
      timeline[:enacted] = false
    end
    
    passed = nil
    if concurring_vote = votes.select {|vote| vote[:passage_type] == 'vote2'}.last
      if concurring_vote[:result] == 'pass' and state !~ /PASS_BACK/
        passed = true
      else
        passed = false
      end
    else
      passed = false
    end
    
    # finally, set the awaiting_signature flag, inferring it from the details above
    if passed and !timeline[:vetoed] and !timeline[:enacted] and topresident_action = doc.search('//actions/topresident').last
      timeline[:awaiting_signature_since] = Utils.govtrack_time_for topresident_action['datetime']
      timeline[:awaiting_signature] = true
    else
      timeline[:awaiting_signature] = false
    end
    
    timeline
  end
  
  def self.most_recent_title_from(titles, type)
    groups = titles.select {|t| t[:type] == type.to_s}.group_by {|t| t[:as]}
    recent_group = groups[groups.keys.last]
    recent_group and recent_group.any? ? recent_group.first[:title] : nil
  end
  
  def self.actions_for(doc)
    doc.search('//actions/*').reject {|a| a.class == Nokogiri::XML::Text}.map do |action|
      {
        :acted_at => Utils.govtrack_time_for(action['datetime']),
        :text => (action/:text).inner_text,
        :type => action.name
      }
    end
  end
  
  # go through the actions and find the last one that is in the past
  # (some bills will have future scheduled committee hearings as "actions")
  def self.last_action_for(actions)
    return nil if actions.size == 0
    
    now = Time.now
    actions.reverse.each do |action|
      return action if action[:acted_at] < Time.now
    end
    
    nil
  end
  
  def self.passage_votes_for(doc)
    chamber = {'h' => 'house', 's' => 'senate'}
    doc.search('//actions/vote|//actions/vote2|//actions/vote-aux').map do |vote|
      voted_at = Utils.govtrack_time_for vote['datetime']
      chamber_code = vote['where']
      how = vote['how']
      
      result = {
        :how => how,
        :result => vote['result'], 
        :voted_at => voted_at,
        :text => (vote/:text).inner_text,
        :chamber => chamber[chamber_code],
        :passage_type => vote['type']
      }
      
      if vote['roll'].present?
        result[:roll_id] = "#{chamber_code}#{vote['roll']}-#{voted_at.year}"
      end
      
      result
    end
  end
  
  def self.keywords_for(doc)
    doc.search('//subjects/term').map {|term| term['name']}
  end
  
  def self.committees_for(filename, doc, cached_committees, missing_committees)
    committees = {}
    
    doc.search("//committees/committee").each do |elem|
      activity = elem['activity'].split(/, ?/).map {|a| a.downcase}
      committee_name = elem['name']
      subcommittee_name = elem['subcommittee']
      
      if subcommittee_name.blank? # we're not getting subcommittees, way too hard to match them up
        if committee = committee_match(committee_name, cached_committees)
          committees[committee['committee_id']] = {
            :activity => activity,
            :committee => Utils.committee_for(committee)
          }
        else
          missing_committees << [committee_name, filename]
        end
      end
    end
    
    committees
  end
  
  def self.committee_match(name, cached_committees)
    Committee.where(:committee_id => cached_committees[name]).first
  end
  
  def self.cached_committees_for(session, doc)
    committees = {}
    
    doc.search("/committees/committee/thomas-names/name[@session=#{session}]").each do |elem|
      committees[elem.text] = Utils.committee_id_for elem.parent.parent['code']
    end
    
    # hardcode in a fix to a usual problem, sigh
    committees["House Ethics"] = "HSSO"
    committees["Senate Caucus on International Narcotics Control"] = "SCNC"
    committees["Commission on Security and Cooperation in Europe (Helsinki Commission)"] = "JCSE"
    
    committees
  end
  
  # known relations
  # supersedes, superseded, identical, rule, unknown
  def self.related_bills_for(doc)
    related_bills = {}
    
    doc.search("//relatedbills/bill").map do |elem|
      relation = elem['relation']
      type = Utils.bill_type_for elem['type']
      bill_id = "#{type}#{elem['number']}-#{elem['session']}"
      
      related_bills[relation] ||= []
      related_bills[relation] << bill_id
    end
    
    related_bills
  end

  def self.old_legislators_for(doc)
    cache = {}
    (doc/:person).each do |person|
      cache[person['id']] = person['bioguideid']
    end
    cache
  end

  def self.question_for(bill)
    "On #{Utils.format_bill_code bill.bill_type, bill.number}"
  end

end