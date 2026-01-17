#===============================================================================
# KIF Mod: Mega Stones Ver. 1.0
# Author: yoko_vdr on discord
#===============================================================================
# What this mod does:
#
# 1) Adds Mega Stones to the game!
# 2) If a species with a mega stone gets it to hold, it gets stat/ability/type changes.
# 3) Fusion support: Fusions containing a species with a mega stone also get these changes.
# 4) Fusion mega stone type changes will be applied according to head/body, the ability will always apply.
# 5) How to gain stones: When you fuse two of the same species, they will hold the mega stone after fusing.
# 6) Species with multiple stones will get the other stones added to the player's inventory.
# 7) Contact me in the Kuray Hub if you want your own mega stone added to the list!
#===============================================================================

#-------------------------------------------------------------------------------
# Logging helper
#-------------------------------------------------------------------------------
module MegaStonesLog

  # Write a boot/status line to MegaStones_boot.txt (timestamped).
  # Used for early diagnostics during script load; failures are swallowed.
  def self.boot(msg)
    begin
      File.open("MegaStones_boot.txt", "a") { |f| f.puts("[#{Time.now}] #{msg}") }
    rescue
    end
  end

  # Append a timestamped info line to MegaStones_register_log.txt.
  # Used for progress/debug logging (registration, icon copying, auto-equip, etc.).
  def self.log(msg)
    begin
      File.open("MegaStones_register_log.txt", "a") { |f| f.puts("[#{Time.now}] #{msg}") }
    rescue
    end
  end

  # Append an exception report (where, message, backtrace) to MegaStones_errorlog.txt.
  # All wrapped in begin/rescue so logging errors never crash the game.
  def self.err(e, where)
    begin
      File.open("MegaStones_errorlog.txt", "a") do |f|
        f.puts "[#{Time.now}] #{where}"
        f.puts "#{e.class}: #{e.message}"
        bt = e.backtrace || []
        f.puts bt.join("\n")
        f.puts "-" * 80
      end
    rescue
    end
  end
end

MegaStonesLog.boot("Loaded. CWD=#{(Dir.pwd rescue 'unknown')}")

#===============================================================================
# Icon management 
#===============================================================================
module MegaStoneIcons
  @hooked_icon = false
  @icons_done  = false

  # Create a directory path if it does not exist (including parents).
  # Splits the path into segments and calls Dir.mkdir step-by-step; ignores failures.
  def self.ensure_dir(path)
    begin
      return if Dir.exist?(path)
    rescue
    end
    parts = path.split(/[\/\\]/)
    cur = ""
    parts.each do |p|
      next if p.nil? || p == ""
      cur = (cur == "" ? p : (cur + "/" + p))
      begin
        Dir.mkdir(cur) unless Dir.exist?(cur)
      rescue
      end
    end
  end

  # Copy only if destination does not exist.
  # Returns TRUE only when a file was actually written.
  def self.safe_copy(src, dst)
    begin
      return false if File.exist?(dst)
    rescue
    end
    begin
      data = nil
      File.open(src, "rb") { |f| data = f.read }
      return false if data.nil?
      File.open(dst, "wb") { |f| f.write(data) }
      return true
    rescue
      return false
    end
  end

  # Check whether a bitmap/file exists for a path (optionally without .png extension).
  # Prefers pbResolveBitmap when available (Essentials-style), otherwise checks the filesystem.
  def self.resolve_exists?(path_no_ext)
    begin
      if defined?(pbResolveBitmap)
        r = pbResolveBitmap(path_no_ext)
        return !r.nil?
      end
    rescue
    end
    begin
      return true if File.exist?(path_no_ext)
      return true if File.exist?(path_no_ext + ".png")
    rescue
    end
    false
  end

  # Normalize an item identifier into a Symbol (e.g. :MEWTWONITE_X).
  # Handles Symbols directly, integers via GameData::Item id_number lookup, objects with #id, 
  # and Strings like "MEWTWONITE_X" or ":MEWTWONITE_X".
  def self.normalize_item_symbol(raw)
    return nil if raw.nil?
    return raw if raw.is_a?(Symbol)

    if raw.is_a?(Integer) && defined?(GameData::Item)
      begin
        GameData::Item.each do |it|
          n = nil
          begin
            n = it.id_number
          rescue
            n = nil
          end
          if n == raw
            begin
              return it.id
            rescue
              return nil
            end
          end
        end
      rescue
      end
    end

    begin
      if raw.respond_to?(:id)
        rid = raw.id
        return rid if rid.is_a?(Symbol)
      end
    rescue
    end

    if raw.is_a?(String)
      s = raw.strip
      if s.start_with?(":")
        begin
          return s[1..-1].to_sym
        rescue
          return nil
        end
      end
      begin
        return s.to_sym
      rescue
        return nil
      end
    end

    nil
  end

  # Build the default Graphics/Items icon path (without extension) for a given item symbol.
  def self.icon_path_no_ext_for(sym)
    "Graphics/Items/#{sym}"
  end

  # Only copies icons if the source icon exists.
  # Looks for MegaStoneIcons in multiple likely places:
  #   - next to this script (if __FILE__ has a directory)
  #   - GameRoot/Mods/MegaStoneIcons (common KIF/KIP setup)
  #   - GameRoot/mods/MegaStoneIcons
  #   - GameRoot/MegaStoneIcons (optional)
  def self.ensure_icons_present!
    return if @icons_done
    return unless defined?(GameData::Item) && GameData::Item.respond_to?(:get)

    begin
      mod_dir = nil
      begin
        mod_dir = File.dirname(__FILE__)
      rescue
        mod_dir = "."
      end

      cwd = (Dir.pwd rescue ".")
      items_dir = cwd + "/Graphics/Items"
      ensure_dir(items_dir)

      candidates = []
      candidates << (mod_dir + "/MegaStoneIcons") if mod_dir
      candidates << (cwd + "/Mods/MegaStoneIcons")
      candidates << (cwd + "/mods/MegaStoneIcons")
      candidates << (cwd + "/MegaStoneIcons")

      assets_dir = nil
      candidates.each do |p|
        begin
          if p && Dir.exist?(p)
            assets_dir = p
            break
          end
        rescue
        end
      end

      if assets_dir.nil?
        MegaStonesLog.log("No icon asset folder found; tried: " + candidates.compact.join(" | "))
        @icons_done = true
        return
      end

      MegaStonesLog.log("Icon copy: assets_dir=#{assets_dir} items_dir=#{items_dir}")

      syms = []
      begin
        if defined?(MegaStoneItems) && MegaStoneItems.const_defined?(:STONES)
          MegaStoneItems::STONES.each { |s| syms << s[:sym] }
        end
      rescue
        syms = []
      end

      copied_any = false

      syms.each do |sym|
        next if sym.nil?
        base = sym.to_s

        src = nil
        begin
          src_candidates = [
            assets_dir + "/#{base}.png",
            assets_dir + "/#{base}.PNG",
            assets_dir + "/#{base.downcase}.png",
            assets_dir + "/#{base.downcase}.PNG"
          ]
          src_candidates.each do |p|
            if File.exist?(p)
              src = p
              break
            end
          end
        rescue
          src = nil
        end

        if src.nil?
          MegaStonesLog.log("Icon: #{sym} SOURCE MISSING (looked for #{assets_dir}/#{base}.png)")
          next
        end

        dst_sym = items_dir + "/#{base}.png"
        begin
          if File.exist?(dst_sym)
            MegaStonesLog.log("Icon: #{sym} DEST EXISTS (#{dst_sym}) [skip]")
          else
            ok = safe_copy(src, dst_sym)
            copied_any ||= ok
            MegaStonesLog.log(ok ? "Icon: #{sym} COPIED -> #{dst_sym}" : "Icon: #{sym} COPY FAILED -> #{dst_sym}")
          end
        rescue
        end

      end

      MegaStonesLog.log(copied_any ? "Icon copy result: COPIED AT LEAST ONE FILE" : "Icon copy result: NOTHING COPIED")
    rescue => e
      MegaStonesLog.err(e, "MegaStoneIcons.ensure_icons_present!")
    end

    @icons_done = true
  end

  # Monkey-patch pbItemIconFile so mega stones can still show icons even if the base lookup fails.
  # Workflow: call the original pbItemIconFile; if it resolves, keep it. 
  # Otherwise normalize the item to a symbol and try Graphics/Items/<SYM>.
  def self.install_icon_fallback_hook!
    return if @hooked_icon

    begin
      if Kernel.private_method_defined?(:pbItemIconFile)
        Kernel.module_eval do
          alias __megastones_orig_pbItemIconFile pbItemIconFile

          # Hooked item icon resolver: falls back to Graphics/Items/<item_symbol> when the original pbItemIconFile result does not exist.
          # This helps custom-registered stones show icons even if the engine's default lookup fails.
          def pbItemIconFile(item)
            f = __megastones_orig_pbItemIconFile(item)

            begin
              if f && MegaStoneIcons.resolve_exists?(f)
                return f
              end
            rescue
            end

            sym = MegaStoneIcons.normalize_item_symbol(item)
            if sym
              alt = MegaStoneIcons.icon_path_no_ext_for(sym)
              begin
                return alt if MegaStoneIcons.resolve_exists?(alt)
              rescue
              end
            end

            f
          end
        end

        MegaStonesLog.log("Installed pbItemIconFile fallback hook.")
        @hooked_icon = true
      end
    rescue => e
      MegaStonesLog.err(e, "MegaStoneIcons.install_icon_fallback_hook!")
    end
  end
end

#===============================================================================
# 1) Item registration: adds stones into GameData. Item Index begins at 6000 for Mega Stones
#===============================================================================
module MegaStoneItems
  START_ID_NUMBER = 6000

  STONES = [
    { sym: :CHARIZARDITE_X, name: "Charizardite X",
      desc: "A mysterious stone. Have Charizard or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :CHARIZARDITE_Y, name: "Charizardite Y",
      desc: "A mysterious stone. Have Charizard or a fusion containing it hold this to unlock its true potential!", price: 0 },  
    { sym: :GENGARITE, name: "Gengarite",
      desc: "A mysterious stone. Have Gengar or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :LOPUNNITE, name: "Lopunnite",
      desc: "A mysterious stone. Have Lopunny or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :ABSOLITE, name: "Absolite",
      desc: "A mysterious stone. Have Absol or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :AERODACTYLITE, name: "Aerodactylite",
      desc: "A mysterious stone. Have Aerodactyl or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :AGGRONITE, name: "Aggronite",
      desc: "A mysterious stone. Have Aggron or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :ALAKAZITE, name: "Alakazite",
      desc: "A mysterious stone. Have Alakazam or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :ALTARIANITE, name: "Altarianite",
      desc: "A mysterious stone. Have Altaria or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :AMPHAROSITE, name: "Ampharosite",
      desc: "A mysterious stone. Have Ampharos or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :BANETTITE, name: "Banettite",
      desc: "A mysterious stone. Have Banette or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :BEEDRILLITE, name: "Beedrillite",
      desc: "A mysterious stone. Have Beedrill or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :BLASTOISINITE, name: "Blastoisinite",
      desc: "A mysterious stone. Have Blastoise or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :BLAZIKENITE, name: "Blazikenite",
      desc: "A mysterious stone. Have Blaziken or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :CAMERUPTITE, name: "Cameruptite",
      desc: "A mysterious stone. Have Camerupt or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :DIANCITE, name: "Diancite",
      desc: "A mysterious stone. Have Diancie or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GALLADITE, name: "Galladite",
      desc: "A mysterious stone. Have Gallade or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GARCHOMPITE, name: "Garchompite",
      desc: "A mysterious stone. Have Garchomp or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GARDEVOIRITE, name: "Gardevoirite",
      desc: "A mysterious stone. Have Gardevoir or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GLALITITE, name: "Glalitite",
      desc: "A mysterious stone. Have Glalie or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GYARADOSITE, name: "Gyaradosite",
      desc: "A mysterious stone. Have Gyarados or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :HERACRONITE, name: "Heracronite",
      desc: "A mysterious stone. Have Heracross or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :HOUNDOOMINITE, name: "Houndoominite",
      desc: "A mysterious stone. Have Houndoom or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :KANGASKHANITE, name: "Kangaskhanite",
      desc: "A mysterious stone. Have Kangaskhan or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :LATIASITE, name: "Latiasite",
      desc: "A mysterious stone. Have Latias or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :LATIOSITE, name: "Latiosite",
      desc: "A mysterious stone. Have Latios or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :LUCARIONITE, name: "Lucarionite",
      desc: "A mysterious stone. Have Lucario hold it to stop wearing stupid shorts.", price: 0 },
    { sym: :LUCARIONITE_Z, name: "Lucarionite Z",
      desc: "A mysterious stone. Have Lucario hold it to stop wearing stupid shorts.", price: 0 },
    { sym: :MAWILITE, name: "Mawilite",
      desc: "A mysterious stone. Have Mawile or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :METAGROSSITE, name: "Metagrossite",
      desc: "A mysterious stone. Have Metagross or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :MEWTWONITE_X, name: "Mewtwonite X",
      desc: "A mysterious stone. Have Mewtwo or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :MEWTWONITE_Y, name: "Mewtwonite Y",
      desc: "A mysterious stone. Have Mewtwo or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :PIDGEOTITE, name: "Pidgeotite",
      desc: "A mysterious stone. Have Pidgeot or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :PINSIRITE, name: "Pinsirite",
      desc: "A mysterious stone. Have Pinsir or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :RAYQUAZATITE, name: "Rayquazatite",
      desc: "A mysterious stone. Have Rayquaza or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SABLENITE, name: "Sablenite",
      desc: "A mysterious stone. Have Sableye or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SALAMENCITE, name: "Salamencite",
      desc: "A mysterious stone. Have Salamence or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SCEPTILITE, name: "Sceptilite",
      desc: "A mysterious stone. Have Sceptile or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SCIZORITE, name: "Scizorite",
      desc: "A mysterious stone. Have Scizor or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SHARPEDONITE, name: "Sharpedonite",
      desc: "A mysterious stone. Have Sharpedo or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SLOWBRONITE, name: "Slowbronite",
      desc: "A mysterious stone. Have Slowbro or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :STEELIXITE, name: "Steelixite",
      desc: "A mysterious stone. Have Steelix or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SWAMPERTITE, name: "Swampertite",
      desc: "A mysterious stone. Have Swampert or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :TYRANITARITE, name: "Tyranitarite",
      desc: "A mysterious stone. Have Tyranitar or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :VENUSAURITE, name: "Venusaurite",
      desc: "A mysterious stone. Have Venusaur or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :CLEFABLITE, name: "Clefablite",
      desc: "A mysterious stone. Have Clefable or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :VICTREEBELITE, name: "Victreebelite",
      desc: "A mysterious stone. Have Victreebel or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :STARMINITE, name: "Starminite",
      desc: "A mysterious stone. Have Starmie or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :DRAGONINITE, name: "Dragoninite",
      desc: "A mysterious stone. Have Dragonite or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :MEGANIUMITE, name: "Meganiumite",
      desc: "A mysterious stone. Have Meganium or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :FERALIGITE, name: "Feraligite",
      desc: "A mysterious stone. Have Feraligatr or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SKARMORITE, name: "Skarmorite",
      desc: "A mysterious stone. Have Skarmory or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :FROSLASSITE, name: "Froslassite",
      desc: "A mysterious stone. Have Froslass or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SCOLIPITE, name: "Scolipite",
      desc: "A mysterious stone. Have Scolipede or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :SCRAFTINITE, name: "Scraftinite",
      desc: "A mysterious stone. Have Scrafty or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :CHANDELURITE, name: "Chandelurite",
      desc: "A mysterious stone. Have Chandelure or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :CHESTNAUGHTITE, name: "Chestnaughtite",
      desc: "A mysterious stone. Have Chestnaught or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :DELPHOXITE, name: "Delphoxite",
      desc: "A mysterious stone. Have Delphox or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GRENINJITE, name: "Greninjite",
      desc: "A mysterious stone. Have Greninja or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :DRAGALGITE, name: "Dragalgite",
      desc: "A mysterious stone. Have Dragalge or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :HAWLUCHANITE, name: "Hawluchanite",
      desc: "A mysterious stone. Have Hawlucha or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :RAICHUNITE_X, name: "Raichunite X",
      desc: "A mysterious stone. Have Raichu or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :RAICHUNITE_Y, name: "Raichunite Y",
      desc: "A mysterious stone. Have Raichu or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :ABSOLITE_Z, name: "Absolite Z",
      desc: "A mysterious stone. Have Absol or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GARCHOMPITE_Z, name: "Garchompite Z",
      desc: "A mysterious stone. Have Garchomp or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :DARKRANITE, name: "Darkranite",
      desc: "A mysterious stone. Have Darkrai or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GOLURKITE, name: "Golurkite",
      desc: "A mysterious stone. Have Golurk or a fusion containing it hold this to unlock its true potential!", price: 0 },
    { sym: :GOLISOPITE, name: "Golisopite",
      desc: "A mysterious stone. Have Golisopod or a fusion containing it hold this to unlock its true potential!", price: 0 }
  ]

  @registered = false

  # Detect which item registration API is available in this engine/fork.
  # Returns [name, module] for GameData::Item.register or Item.register, or nil if none is available.
  def self.registrar
    if defined?(GameData::Item) && GameData::Item.respond_to?(:register)
      return [:gamedata_item, GameData::Item]
    end
    if defined?(Item) && Item.respond_to?(:register)
      return [:item_alias, Item]
    end
    nil
  end

  # Sanity-check that required systems exist before attempting registration.
  # Ensures MessageTypes and GameData::Item helpers exist, and that a registrar API was found.
  def self.ready?
    return false unless defined?(MessageTypes) && MessageTypes.respond_to?(:set)
    return false unless defined?(GameData::Item) && GameData::Item.respond_to?(:each) &&
                        GameData::Item.respond_to?(:exists?) && GameData::Item.respond_to?(:get)
    !!registrar
  end

  # Collect a set of already-used GameData::Item id_number values.
  # Used to avoid collisions when assigning ids to newly-registered mega stones.
  def self.used_id_numbers
    used = {}
    begin
      GameData::Item.each do |it|
        n = nil
        begin
          n = it.id_number
        rescue
          n = nil
        end
        used[n] = true if n.is_a?(Integer)
      end
    rescue
    end
    used
  end

  # Register one new item in the chosen registrar and populate MessageTypes name/description tables.
  # This is the low-level "create item" routine used by register_once!.
  def self.register_one(reg_mod, sym, id_number, name, price, desc)
    plural = name + "s"
    reg_mod.register({
      :id          => sym,
      :id_number   => id_number,
      :name        => name,
      :name_plural => plural,
      :pocket      => 1,
      :price       => price,
      :description => desc,
      :field_use   => 0,
      :battle_use  => 0,
      :type        => 0,
      :move        => nil
    })
    MessageTypes.set(MessageTypes::Items,            id_number, name)
    MessageTypes.set(MessageTypes::ItemPlurals,      id_number, plural)
    MessageTypes.set(MessageTypes::ItemDescriptions, id_number, desc)
  end

  # Register all stones from STONES into GameData exactly once per game boot.
  # Skips if the item already exists, chooses free id_numbers starting from START_ID_NUMBER, and logs each decision.
  def self.register_once!
    return if @registered

    api = registrar
    MegaStonesLog.log("register_once! ready?=#{ready?} api=#{api.inspect}")
    return unless ready?
    api_name, reg_mod = api

    begin
      used = used_id_numbers
      id_here = START_ID_NUMBER
      MegaStonesLog.log("Using registrar=#{api_name}")

      STONES.each do |s|
        sym   = s[:sym]
        name  = s[:name]
        desc  = s[:desc]  || ""
        price = s[:price] || 0

        exists = false
        begin
          exists = GameData::Item.exists?(sym)
        rescue
          exists = false
        end

        if exists
          it = nil
          begin
            it = GameData::Item.get(sym)
          rescue
            it = nil
          end
          MegaStonesLog.log("SKIP #{sym}: exists (id_number=#{(it ? (it.id_number rescue nil) : nil).inspect})")
          next
        end

        id_here += 1 while used[id_here]
        used[id_here] = true

        register_one(reg_mod, sym, id_here, name, price, desc)
        MegaStonesLog.log("OK #{sym}: id_number=#{id_here}")

        id_here += 1
      end

      @registered = true
      MegaStonesLog.log("DONE registration")
    rescue => e
      MegaStonesLog.err(e, "MegaStoneItems.register_once! (api=#{api.inspect})")
    end
  end
end

#===============================================================================
# 2) Mega logic (held effects + fusion + self-fusion auto-equip)
#===============================================================================
module MegaStoneSim
  ITEM_EFFECTS = {
    :CHARIZARDITE_X => {
      species: :CHARIZARD,
      rule: {
        types:   [:FIRE, :DRAGON],
        ability: :TOUGHCLAWS,
        base_stats_add: { ATTACK: 46, DEFENSE: 33, SPECIAL_ATTACK: 21 }
      }
    },
    :CHARIZARDITE_Y => {
      species: :CHARIZARD,
      rule: {
        types:   [:FIRE, :FLYING],
        ability: :DROUGHT,
        base_stats_add: { ATTACK: 20, SPECIAL_ATTACK: 50, SPECIAL_DEFENSE: 30 }
      }
    },
    :GENGARITE => {
      species: :GENGAR,
      rule: {
        types:   [:GHOST, :POISON],
        ability: :SHADOWTAG,
        base_stats_add: { DEFENSE: 20, SPECIAL_ATTACK: 40, SPECIAL_DEFENSE: 20, SPEED: 20 }
      }
    },
    :LOPUNNITE => {
      species: :LOPUNNY,
      rule: {
        types:   [:NORMAL, :FIGHTING],
        ability: :SCRAPPY,
        base_stats_add: { ATTACK: 60, DEFENSE: 10, SPEED: 30 }
      }
    },
    :ABSOLITE => {
      species: :ABSOL,
      rule: {
        types:   [:DARK, :DARK],
        ability: :MAGICBOUNCE,
        base_stats_add: { ATTACK: 20, SPECIAL_ATTACK: 40, SPEED: 40 }
      }
    },
    :ABSOLITE_Z => {
      species: :ABSOL,
      rule: {
        types:   [:DARK, :GHOST],
        ability: :JUSTIFIED,
        base_stats_add: { ATTACK: 24, SPEED: 76 }
      }
    },
    :AERODACTYLITE => {
      species: :AERODACTYL,
      rule: {
        types:   [:ROCK, :FLYING],
        ability: :TOUGHCLAWS,
        base_stats_add: {ATTACK: 30, DEFENSE: 20, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 20, SPEED: 20}
      }
    },
    :AGGRONITE => {
      species: :AGGRON,
      rule: {
        types:   [:STEEL, :STEEL],
        ability: :FILTER,
        base_stats_add: { ATTACK: 30, DEFENSE: 50, SPECIAL_DEFENSE: 20}
      }
    },
    :ALAKAZITE => {
      species: :ALAKAZAM,
      rule: {
        types:   [:PSYCHIC, :PSYCHIC],
        ability: :TRACE,
        base_stats_add: {DEFENSE: 20, SPECIAL_ATTACK: 40, SPECIAL_DEFENSE: 10, SPEED: 30}
      }
    },
    :ALTARIANITE => {
      species: :ALTARIA,
      rule: {
        types:   [:DRAGON, :FAIRY],
        ability: :PIXILATE,
        base_stats_add: {ATTACK: 40, DEFENSE: 20, SPECIAL_ATTACK: 40}
      }
    },
    :AMPHAROSITE => {
      species: :AMPHAROS,
      rule: {
        types:   [:ELECTRIC, :DRAGON],
        ability: :MOLDBREAKER,
        base_stats_add: {ATTACK: 20, DEFENSE: 20, SPECIAL_ATTACK: 50, SPECIAL_DEFENSE: 20, SPEED: -10}
      }
    },
    :BANETTITE => {
      species: :BANETTE,
      rule: {
        types:   [:GHOST, :GHOST],
        ability: :PRANKSTER,
        base_stats_add: {ATTACK: 50, DEFENSE: 10, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 20, SPEED: 10}
      }
    },
    :BEEDRILLITE => {
      species: :BEEDRILL,
      rule: {
        types:   [:BUG, :POISON],
        ability: :ADAPTABILITY,
        base_stats_add: {ATTACK: 60, SPECIAL_ATTACK: -30, SPEED: 70}
      }
    },
    :BLASTOISINITE => {
      species: :BLASTOISE,
      rule: {
        types:   [:WATER, :WATER],
        ability: :ADAPTABILITY, # Mega Launcher doesn't exist in IF
        base_stats_add: {ATTACK: 20, DEFENSE: 20, SPECIAL_ATTACK: 50, SPECIAL_DEFENSE: 10}
      }
    },
    :BLAZIKENITE => {
      species: :BLAZIKEN,
      rule: {
        types:   [:FIRE, :FIGHTING],
        ability: :SPEEDBOOST,
        base_stats_add: { ATTACK: 40, DEFENSE: 10, SPECIAL_ATTACK: 20, SPECIAL_DEFENSE: 10, SPEED: 20}
      }
    },
    :CAMERUPTITE => {
      species: :CAMERUPT,
      rule: {
        types:   [:FIRE, :GROUND],
        ability: :SHEERFORCE,
        base_stats_add: { ATTACK: 20, DEFENSE: 30, SPECIAL_ATTACK: 40, SPECIAL_DEFENSE: 30, SPEED: -20}
      }
    },
    :DIANCITE => {
      species: :DIANCIE,
      rule: {
        types:   [:ROCK, :FAIRY],
        ability: :MAGICBOUNCE,
        base_stats_add: { ATTACK: 60, DEFENSE: -40, SPECIAL_ATTACK: 60, SPECIAL_DEFENSE: -40, SPEED: 60}
      }
    },
    :GALLADITE => {
      species: :GALLADE,
      rule: {
        types:   [:PSYCHIC, :FIGHTING],
        ability: :INNERFOCUS,
        base_stats_add: { ATTACK: 40, DEFENSE: 30, SPEED: 30 }
      }
    },
    :GARCHOMPITE => {
      species: :GARCHOMP,
      rule: {
        types:   [:DRAGON, :GROUND],
        ability: :SANDFORCE,
        base_stats_add: { ATTACK: 40, DEFENSE: 20, SPECIAL_ATTACK: 40, SPECIAL_DEFENSE: 10, SPEED: 10 }
      }
    },
    :GARDEVOIRITE => {
      species: :GARDEVOIR,
      rule: {
        types:   [:PSYCHIC, :FAIRY],
        ability: :PIXILATE,
        base_stats_add: { ATTACK: 20, SPECIAL_ATTACK: 40, SPECIAL_DEFENSE: 20, SPEED: 20 }
      }
    },
    :GLALITITE => {
      species: :GLALIE,
      rule: {
        types:   [:ICE, :ICE],
        ability: :REFRIGERATE,
        base_stats_add: { ATTACK: 40, SPECIAL_ATTACK: 40, SPEED: 20 }
      }
    },
    :GYARADOSITE => {
      species: :GYARADOS,
      rule: {
        types:   [:WATER, :DARK],
        ability: :MOLDBREAKER,
        base_stats_add: { ATTACK: 30, DEFENSE: 30, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 30 }
      }
    },
    :HERACRONITE => {
      species: :HERACROSS,
      rule: {
        types:   [:BUG, :FIGHTING],
        ability: :SKILLLINK,
        base_stats_add: { ATTACK: 60, DEFENSE: 40, SPECIAL_DEFENSE: 10, SPEED: -10 }
      }
    },
    :HOUNDOOMINITE => {
      species: :HOUNDOOM,
      rule: {
        types:   [:DARK, :FIRE],
        ability: :SOLARPOWER,
        base_stats_add: { DEFENSE: 40, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 10, SPEED: 20 }
      }
    },
    :KANGASKHANITE => {
      species: :KANGASKHAN,
      rule: {
        types:   [:NORMAL, :NORMAL],
        ability: :ADAPTABILITY, # Parental Bond doesn't exist in IF
        base_stats_add: { ATTACK: 30, DEFENSE: 20, SPECIAL_ATTACK: 20, SPECIAL_DEFENSE: 20, SPEED: 10 }
      }
    },
    :LATIASITE => {
      species: :LATIAS,
      rule: {
        types:   [:DRAGON, :PSYCHIC],
        ability: :LEVITATE,
        base_stats_add: { ATTACK: 20, DEFENSE: 30, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 20 }
      }
    },
    :LATIOSITE => {
      species: :LATIOS,
      rule: {
        types:   [:DRAGON, :PSYCHIC],
        ability: :LEVITATE,
        base_stats_add: { ATTACK: 40, DEFENSE: 20, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 10 }
      }
    },
    :LUCARIONITE => {
      species: :LUCARIO,
      rule: {
        types:   [:FIGHTING, :STEEL],
        ability: :ADAPTABILITY,
        base_stats_add: { ATTACK: 35, DEFENSE: 18, SPECIAL_ATTACK: 25, SPEED: 22 }
      }
    },
    :MAWILITE => {
      species: :MAWILE,
      rule: {
        types:   [:STEEL, :FAIRY],
        ability: :HUGEPOWER,
        base_stats_add: { ATTACK: 20, DEFENSE: 40, SPECIAL_DEFENSE: 40 }
      }
    },
    :METAGROSSITE => {
      species: :METAGROSS,
      rule: {
        types:   [:STEEL, :PSYCHIC],
        ability: :TOUGHCLAWS,
        base_stats_add: { ATTACK: 10, DEFENSE: 20, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 20, SPEED: 40 }
      }
    },
    :MEWTWONITE_X => {
      species: :MEWTWO,
      rule: {
        types:   [:PSYCHIC, :FIGHTING],
        ability: :STEADFAST,
        base_stats_add: { ATTACK: 80, DEFENSE: 10, SPECIAL_DEFENSE: 10 }
      }
    },
    :MEWTWONITE_Y => {
      species: :MEWTWO,
      rule: {
        types:   [:PSYCHIC, :PSYCHIC],
        ability: :INSOMNIA,
        base_stats_add: { ATTACK: 40, DEFENSE: -20, SPECIAL_ATTACK: 40, SPECIAL_DEFENSE: 30, SPEED: 10 }
      }
    },
    :PIDGEOTITE => {
      species: :PIDGEOT,
      rule: {
        types:   [:NORMAL, :FLYING],
        ability: :NOGUARD,
        base_stats_add: { DEFENSE: 5, SPECIAL_ATTACK: 65, SPECIAL_DEFENSE: 10, SPEED: 20 }
      }
    },
    :PINSIRITE => {
      species: :PINSIR,
      rule: {
        types:   [:BUG, :FLYING],
        ability: :ADAPTABILITY, # Aerilate doesn't exist in IF
        base_stats_add: { ATTACK: 30, DEFENSE: 20, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 20, SPEED: 20 }
      }
    },
    :RAYQUAZATITE => {
      species: :RAYQUAZA,
      rule: {
        types:   [:DRAGON, :FLYING],
        ability: :AIRLOCK, # Delta Stream doesn't exist in IF
        base_stats_add: { ATTACK: 30, DEFENSE: 10, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 10, SPEED: 20 }
      }
    },
    :SABLENITE => {
      species: :SABLEYE,
      rule: {
        types:   [:DARK, :GHOST],
        ability: :MAGICBOUNCE,
        base_stats_add: { ATTACK: 10, DEFENSE: 50, SPECIAL_ATTACK: 20, SPECIAL_DEFENSE: 50, SPEED: -30 }
      }
    },
    :SALAMENCITE => {
      species: :SALAMENCE,
      rule: {
        types:   [:DRAGON, :FLYING],
        ability: :MOXIE, # Aerilate doesn't exist in IF
        base_stats_add: { ATTACK: 10, DEFENSE: 50, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 10, SPEED: 20 }
      }
    },
    :SCEPTILITE => {
      species: :SCEPTILE,
      rule: {
        types:   [:GRASS, :DRAGON],
        ability: :LIGHTNINGROD,
        base_stats_add: { ATTACK: 25, DEFENSE: 10, SPECIAL_ATTACK: 40, SPEED: 25 }
      }
    },
    :SCIZORITE => {
      species: :SCIZOR,
      rule: {
        types:   [:BUG, :STEEL],
        ability: :TECHNICIAN,
        base_stats_add: { ATTACK: 20, DEFENSE: 40, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 20, SPEED: 10 }
      }
    },
    :SHARPEDONITE => {
      species: :SHARPEDO,
      rule: {
        types:   [:WATER, :DARK],
        ability: :STRONGJAW,
        base_stats_add: { ATTACK: 20, DEFENSE: 30, SPECIAL_ATTACK: 15, SPECIAL_DEFENSE: 25, SPEED: 10 }
      }
    },
    :SLOWBRONITE => {
      species: :SLOWBRO,
      rule: {
        types:   [:WATER, :PSYCHIC],
        ability: :SHELLARMOR,
        base_stats_add: { DEFENSE: 70, SPECIAL_ATTACK: 30 }
      }
    },
    :STEELIXITE => {
      species: :STEELIX,
      rule: {
        types:   [:STEEL, :GROUND],
        ability: :SANDFORCE,
        base_stats_add: { ATTACK: 40, DEFENSE: 30, SPECIAL_DEFENSE: 30 }
      }
    },
    :SWAMPERTITE => {
      species: :SWAMPERT,
      rule: {
        types:   [:WATER, :GROUND],
        ability: :SWIFTSWIM,
        base_stats_add: { ATTACK: 40, DEFENSE: 20, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 20, SPEED: 10 }
      }
    },
    :TYRANITARITE => {
      species: :TYRANITAR,
      rule: {
        types:   [:ROCK, :DARK],
        ability: :SANDSTREAM,
        base_stats_add: { ATTACK: 30, DEFENSE: 40, SPECIAL_DEFENSE: 20, SPEED: 10 }
      }
    },
    :VENUSAURITE => {
      species: :VENUSAUR,
      rule: {
        types:   [:GRASS, :POISON],
        ability: :THICKFAT,
        base_stats_add: { ATTACK: 18, DEFENSE: 40, SPECIAL_ATTACK: 22, SPECIAL_DEFENSE: 20 }
      }
    },
    :CLEFABLITE => {
      species: :CLEFABLE,
      rule: {
        types:   [:FAIRY, :FLYING],
        ability: :UNAWARE,
        base_stats_add: { ATTACK: 10, DEFENSE: 20, SPECIAL_ATTACK: 40, SPECIAL_DEFENSE: 20, SPEED: 10 }
      }
    },
    :VICTREEBELITE => {
      species: :VICTREEBEL,
      rule: {
        types:   [:GRASS, :POISON],
        ability: :GLUTTONY,
        base_stats_add: { ATTACK: 20, DEFENSE: 20, SPECIAL_ATTACK: 35, SPECIAL_DEFENSE: 25 }
      }
    },
    :STARMINITE => {
      species: :STARMIE,
      rule: {
        types:   [:WATER, :PSYCHIC],
        ability: :ANALYTIC,
        base_stats_add: { ATTACK: 65, DEFENSE: 20, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 20, SPEED: 5 }
      }
    },
    :DRAGONINITE => {
      species: :DRAGONITE,
      rule: {
        types:   [:DRAGON, :FLYING],
        ability: :MULTISCALE,
        base_stats_add: { ATTACK: -10, DEFENSE: 20, SPECIAL_ATTACK: 45, SPECIAL_DEFENSE: 25, SPEED: 20 }
      }
    },
    :MEGANIUMITE => {
      species: :MEGANIUM,
      rule: {
        types:   [:GRASS, :FAIRY],
        ability: :LEAFGUARD,
        base_stats_add: { ATTACK: 10, DEFENSE: 15, SPECIAL_ATTACK: 60, SPECIAL_DEFENSE: 15 }
      }
    },
    :FERALIGITE => {
      species: :FERALIGATR,
      rule: {
        types:   [:WATER, :DRAGON],
        ability: :SHEERFORCE,
        base_stats_add: { ATTACK: 55, DEFENSE: 25, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 10 }
      }
    },
    :SKARMORITE => {
      species: :SKARMORY,
      rule: {
        types:   [:STEEL, :FLYING],
        ability: :WEAKARMOR,
        base_stats_add: { ATTACK: 60, DEFENSE: -30, SPECIAL_DEFENSE: 30, SPEED: 40 }
      }
    },
    :FROSLASSITE => {
      species: :FROSLASS,
      rule: {
        types:   [:ICE, :GHOST],
        ability: :CURSEDBODY,
        base_stats_add: { SPECIAL_ATTACK: 60, SPECIAL_DEFENSE: 30, SPEED: 10 }
      }
    },
    :SCOLIPITE => {
      species: :SCOLIPEDE,
      rule: {
        types:   [:BUG, :POISON],
        ability: :SPEEDBOOST,
        base_stats_add: { ATTACK: 40, DEFENSE: 60, SPECIAL_ATTACK: 20, SPECIAL_DEFENSE: 30, SPEED: -50 }
      }
    },
    :SCRAFTINITE => {
      species: :SCRAFTY,
      rule: {
        types:   [:DARK, :FIGHTING],
        ability: :INTIMIDATE,
        base_stats_add: { ATTACK: 40, DEFENSE: 20, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 20, SPEED: 10 }
      }
    },
    :CHANDELURITE => {
      species: :CHANDELURE,
      rule: {
        types:   [:GHOST, :FIRE],
        ability: :INFILTRATOR,
        base_stats_add: { ATTACK: 20, DEFENSE: 20, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 20, SPEED: 10 }
      }
    },
    :CHESTNAUGHTITE => {
      species: :CHESTNAUGHT,
      rule: {
        types:   [:GRASS, :FIGHTING],
        ability: :BULLETPROOF,
        base_stats_add: { ATTACK: 30, DEFENSE: 50, SPECIAL_DEFENSE: 40, SPEED: -20 }
      }
    },
    :DELPHOXITE => {
      species: :DELPHOX,
      rule: {
        types:   [:FIRE, :PSYCHIC],
        ability: :MAGICIAN,
        base_stats_add: { SPECIAL_ATTACK: 45, SPECIAL_DEFENSE: 25, SPEED: 30 }
      }
    },
    :GRENINJITE => {
      species: :GRENINJA,
      rule: {
        types:   [:WATER, :DARK],
        ability: :PROTEAN,
        base_stats_add: { ATTACK: 30, DEFENSE: 10, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 10, SPEED: 20 }
      }
    },
    :DRAGALGITE => {
      species: :DRAGALGE,
      rule: {
        types:   [:POISON, :DRAGON],
        ability: :ADAPTABILITY,
        base_stats_add: { ATTACK: 10, DEFENSE: 15, SPECIAL_ATTACK: 35, SPECIAL_DEFENSE: 40 }
      }
    },
    :HAWLUCHANITE => {
      species: :HAWLUCHA,
      rule: {
        types:   [:FIGHTING, :FLYING],
        ability: :MOLDBREAKER,
        base_stats_add: { ATTACK: 45, DEFENSE: 25, SPECIAL_DEFENSE: 30 }
      }
    },
    :RAICHUNITE_X => {
      species: :RAICHU,
      rule: {
        types:   [:ELECTRIC, :ELECTRIC],
        ability: :LIGHTNINGROD,
        base_stats_add: { ATTACK: 45, DEFENSE: 40, SPECIAL_DEFENSE: 15 }
      }
    },
    :RAICHUNITE_Y => {
      species: :RAICHU,
      rule: {
        types:   [:ELECTRIC, :ELECTRIC],
        ability: :LIGHTNINGROD,
        base_stats_add: { ATTACK: 10, SPECIAL_ATTACK: 70, SPEED: 20 }
      }
    },
    :GARCHOMPITE_Z => {
      species: :GARCHOMP,
      rule: {
        types:   [:DRAGON, :DRAGON],
        ability: :ROUGHSKIN,
        base_stats_add: { DEFENSE: -10, SPECIAL_ATTACK: 61, SPEED: 49 }
      }
    },
    :LUCARIONITE_Z => {
      species: :LUCARIO,
      rule: {
        types:   [:FIGHTING, :STEEL],
        ability: :JUSTIFIED,
        base_stats_add: { ATTACK: -10, SPECIAL_ATTACK: 49, SPEED: 61 }
      }
    },
    :DARKRANITE => {
      species: :DARKRAI,
      rule: {
        types:   [:DARK, :DARK],
        ability: :BADDREAMS,
        base_stats_add: { ATTACK: 30, DEFENSE: 40, SPECIAL_ATTACK: 30, SPECIAL_DEFENSE: 40, SPEED: -40 }
      }
    },
    :GOLURKITE => {
      species: :GOLURK,
      rule: {
        types:   [:GROUND, :GHOST],
        ability: :NOGUARD,
        base_stats_add: { ATTACK: 35, DEFENSE: 25, SPECIAL_ATTACK: 15, SPECIAL_DEFENSE: 25 }
      }
    },
    :GOLISOPITE => {
      species: :GOLISOPOD,
      rule: {
        types:   [:BUG, :STEEL],
        ability: :EMERGENCYEXIT,
        base_stats_add: { ATTACK: 25, DEFENSE: 35, SPECIAL_ATTACK: 10, SPECIAL_DEFENSE: 30 }
      }
    }
  }

# Needed, to give self fusions the correct stone. Second stone in Arrays is dropped into the player's inventory. 
  SPECIES_TO_STONE = {
    :CHARIZARD => [:CHARIZARDITE_X, :CHARIZARDITE_Y],
    :GENGAR    => :GENGARITE,
    :LOPUNNY   => :LOPUNNITE,
    :ABSOL     => [:ABSOLITE, :ABSOLITE_Z],
    :AERODACTYL => :AERODACTYLITE,
    :AGGRON    => :AGGRONITE,
    :ALAKAZAM  => :ALAKAZITE,
    :ALTARIA   => :ALTARIANITE,
    :AMPHAROS  => :AMPHAROSITE,
    :BANETTE   => :BANETTITE,
    :BEEDRILL  => :BEEDRILLITE,
    :BLASTOISE => :BLASTOISINITE,
    :BLAZIKEN  => :BLAZIKENITE,
    :CAMERUPT  => :CAMERUPTITE,
    :DIANCIE   => :DIANCITE,
    :GALLADE   => :GALLADITE,
    :GARCHOMP  => [:GARCHOMPITE, :GARCHOMPITE_Z],
    :GARDEVOIR => :GARDEVOIRITE,
    :GLALIE    => :GLALITITE,
    :GYARADOS  => :GYARADOSITE,
    :HERACROSS => :HERACRONITE,
    :HOUNDOOM  => :HOUNDOOMINITE,
    :KANGASKHAN => :KANGASKHANITE,
    :LATIAS    => :LATIASITE,
    :LATIOS    => :LATIOSITE,
    :LUCARIO   => [:LUCARIONITE, :LUCARIONITE_Z],
    :MAWILE    => :MAWILITE,
    :METAGROSS => :METAGROSSITE,
    :MEWTWO    => [:MEWTWONITE_Y, :MEWTWONITE_X], 
    :PIDGEOT   => :PIDGEOTITE,
    :PINSIR    => :PINSIRITE,
    :RAYQUAZA  => :RAYQUAZATITE,
    :SABLEYE   => :SABLENITE,
    :SALAMENCE => :SALAMENCITE,
    :SCEPTILE  => :SCEPTILITE,
    :SCIZOR    => :SCIZORITE,
    :SHARPEDO  => :SHARPEDONITE,
    :SLOWBRO   => :SLOWBRONITE,
    :STEELIX   => :STEELIXITE,
    :SWAMPERT  => :SWAMPERTITE,
    :TYRANITAR => :TYRANITARITE,
    :VENUSAUR  => :VENUSAURITE,
    :CLEFABLE  => :CLEFABLITE,
    :VICTREEBEL => :VICTREEBELITE,
    :STARMIE   => :STARMINITE,
    :DRAGONITE => :DRAGONINITE,
    :MEGANIUM  => :MEGANIUMITE,
    :FERALIGATR => :FERALIGITE,
    :SKARMORY  => :SKARMORITE,
    :FROSLASS  => :FROSLASSITE,
    :SCOLIPEDE => :SCOLIPITE,
    :SCRAFTY   => :SCRAFTINITE,
    :CHANDELURE => :CHANDELURITE,
    :CHESTNAUGHT => :CHESTNAUGHTITE,
    :DELPHOX   => :DELPHOXITE,
    :GRENINJA => :GRENINJITE,
    :DRAGALGE  => :DRAGALGITE,
    :HAWLUCHA  => :HAWLUCHANITE,
    :RAICHU    => [:RAICHUNITE_Y, :RAICHUNITE_X],
    :DARKRAI   => :DARKRANITE,
    :GOLURK    => :GOLURKITE,
    :GOLISOPOD => :GOLISOPITE
  }

  @dumped_items = false

   # Debug helper: write the party's held item raw values and normalized symbols to MegaStones_itemdebug.txt.
   # Useful when the engine stores items as integers/objects and you need to see what is actually in pkmn.item.
   def self.dump_party_items_once!
    return if @dumped_items
    return unless defined?($Trainer) && $Trainer && $Trainer.respond_to?(:party)
    party = $Trainer.party
    return if party.nil? || party.compact.empty?

    lines = []
    lines << "Time: #{Time.now}"

    party.compact.each_with_index do |p, i|
      raw = nil
      begin
        raw = p.item
      rescue
        raw = :err
      end
      sym = MegaStoneIcons.normalize_item_symbol(raw)

      nm = nil
      begin
        nm = p.name
      rescue
        nm = "?"
      end

      sp = nil
      begin
        sp = p.species
      rescue
        sp = "?"
      end

      lines << "[#{i}] #{nm} species=#{sp.inspect}"
      lines << "  raw_item=#{raw.inspect} class=#{(raw.class rescue '?')}"
      lines << "  item_sym=#{sym.inspect}"
    end

    begin
      File.open("MegaStones_itemdebug.txt", "w") { |f| f.puts(lines.join("\n")) }
    rescue
    end
    @dumped_items = true
  end

  # Parse KIF-style fusion species codes like :B6H1 (BodyDex=6, HeadDex=1).
  # Returns [body_dex, head_dex] or [nil, nil] if the species is not a fusion code.
  def self.parse_bh_species_code(pkmn)
    sp = nil
    begin
      sp = pkmn.species
    rescue
      sp = nil
    end
    s = ""
    begin
      s = sp.to_s
    rescue
      s = ""
    end
    return [$1.to_i, $2.to_i] if s =~ /\AB(\d+)H(\d+)\z/i
    [nil, nil]
  end

  # Return true if the Pokemon's species is a fusion code in the B..H.. format.
  def self.fusion_code?(pkmn)
    b, h = parse_bh_species_code(pkmn)
    b.is_a?(Integer) && h.is_a?(Integer)
  end

  # Return the head Pokedex number from a fusion code, or nil if not a fusion.
  def self.fusion_head_dex(pkmn)
    _b, h = parse_bh_species_code(pkmn)
    h
  end

  # Convert a Pokedex number (integer) into a GameData::Species symbol (e.g. 150 -> :MEWTWO).
  # Returns nil if GameData::Species is unavailable or the lookup fails.
  def self.fusion_body_dex(pkmn)
    b, _h = parse_bh_species_code(pkmn)
    b
  end

  def self.dex_to_species_sym(dex)
    return nil unless dex.is_a?(Integer)
    return nil unless defined?(GameData::Species)
    sp = nil
    begin
      sp = GameData::Species.get(dex)
    rescue
      sp = nil
    end
    return nil unless sp
    begin
      return sp.id
    rescue
      nil
    end
  end

  # Convenience: fusion_head_dex -> dex_to_species_sym.
  def self.fusion_head_species(pkmn)
    dex_to_species_sym(fusion_head_dex(pkmn))
  end

  # Convenience: fusion_body_dex -> dex_to_species_sym.
  def self.fusion_body_species(pkmn)
    dex_to_species_sym(fusion_body_dex(pkmn))
  end

  # Try to set pkmn.item to the given mega stone.
  # First tries assigning the Symbol. If the engine expects numeric item ids, 
  # it looks up GameData::Item.get(sym).id_number and assigns that instead.
  def self.try_set_item(pkmn, item_sym)
    return false unless pkmn && pkmn.respond_to?(:item=)

    begin
      pkmn.item = item_sym
      return true
    rescue
    end

    it = nil
    begin
      it = GameData::Item.get(item_sym) if defined?(GameData::Item)
    rescue
      it = nil
    end

    if it
      idn = nil
      begin
        idn = it.id_number
      rescue
        idn = nil
      end
      if idn.is_a?(Integer)
        begin
          pkmn.item = idn
          return true
        rescue
        end
      end
    end

    false
  end

  # Try to silently add an item to the player's bag.
  # Returns true if it *likely* succeeded (API differences across KIF/Essentials).
  def self.try_add_to_bag(item_sym, qty = 1)
    return false if item_sym.nil?
    qty = 1 if qty.nil? || qty <= 0

    # Prefer bag storage APIs (silent) over pbReceiveItem (often shows messages).
    bag = nil
    begin
      bag = $PokemonBag if defined?($PokemonBag) && $PokemonBag
    rescue
      bag = nil
    end
    begin
      bag = $bag if bag.nil? && defined?($bag) && $bag
    rescue
    end
    begin
      bag = $Trainer.bag if bag.nil? && defined?($Trainer) && $Trainer && $Trainer.respond_to?(:bag)
    rescue
    end

    if bag
      [:pbStoreItem, :storeItem, :add].each do |m|
        next unless bag.respond_to?(m)
        begin
          r = bag.send(m, item_sym, qty)
          return true if r
          return true # treat "no exception" as success for void-return APIs
        rescue
        end
      end
    end

    # Fallback: receive-item helper (may display a message in some bases).
    if defined?(pbReceiveItem)
      begin
        r = pbReceiveItem(item_sym, qty)
        return true if r
        return true
      rescue
      end
    end

    false
  end

  def self.no_item?(raw)
    return true if raw.nil?
    return true if raw == 0
    return true if raw == :NONE || raw == :NOITEM || raw == :NO_ITEM || raw == :EMPTY || raw == :AIR
    sym = MegaStoneIcons.normalize_item_symbol(raw)
    return true if sym.nil?
    false
  end

  def self.auto_equip_self_fusions_once!
    return unless defined?($Trainer) && $Trainer && $Trainer.respond_to?(:party)
    party = $Trainer.party
    return if party.nil?

    party.compact.each do |p|
      next unless fusion_code?(p)

      hs = fusion_head_species(p)
      bs = fusion_body_species(p)
      next unless hs && bs
      next unless hs == bs

      desired = SPECIES_TO_STONE[hs]
      next unless desired

      # Use a dedicated flag for "self-fusion stone processing".
      # (Older versions used @megastonesim_autoequipped_selfstone; that can block
      # multi-stone species like MEWTWO, so we intentionally ignore it here.)
      already = false
      begin
        already = p.instance_variable_defined?(:@megastonesim_selffusion_stones_processed) &&
                  p.instance_variable_get(:@megastonesim_selffusion_stones_processed)
      rescue
        already = false
      end
      next if already

      desired_list = (desired.is_a?(Array) ? desired.compact : [desired]).compact
      next if desired_list.empty?

      raw = nil
      begin
        raw = p.item
      rescue
        raw = nil
      end
      held_sym = MegaStoneIcons.normalize_item_symbol(raw)

      # Only auto-equip if the fusion is holding nothing.
      # If it is already holding one of the desired stones, keep it.
      # If it is holding something else, don't touch it and don't grant stones.
      ok = true
      if no_item?(raw)
        ok = try_set_item(p, desired_list[0])
        held_sym = desired_list[0] if ok
      elsif !held_sym.nil? && desired_list.include?(held_sym)
        ok = true
      else
        next
      end

      # If this species has multiple Mega Stones, add the "other" stones to the bag.
      # Example: MEWTWO self-fusion holds MEWTWONITE_Y, and MEWTWONITE_X is added.
      extras = desired_list.dup
      extras.delete(held_sym) if held_sym
      extras.uniq!
      extras.each do |extra_item|
        begin
          try_add_to_bag(extra_item, 1)
        rescue
        end
      end

      begin
        p.instance_variable_set(:@megastonesim_selffusion_stones_processed, true)
      rescue
      end

      if ok
        nm = nil
        begin
          nm = p.name
        rescue
          nm = "?"
        end
        if desired.is_a?(Array) && desired_list.length > 1
          MegaStonesLog.log("AUTOEQUIP self-fusion: #{nm} (#{hs}) -> hold #{held_sym} ; gave #{extras.inspect}")
        else
          MegaStonesLog.log("AUTOEQUIP self-fusion: #{nm} (#{hs}) -> #{held_sym}")
        end
      else
        MegaStonesLog.log("AUTOEQUIP FAILED self-fusion (#{hs}) desired=#{desired.inspect}")
      end
    end
  end

  def self.held_mega_item_sym(pkmn)
    return nil unless pkmn && pkmn.respond_to?(:item)

    raw = nil
    begin
      raw = pkmn.item
    rescue
      raw = nil
    end

    sym = MegaStoneIcons.normalize_item_symbol(raw)
    return sym if sym && ITEM_EFFECTS.key?(sym)
    nil
  end

  # Compute whether mega effects apply to a given Pokemon and, if so, how.
  # For normal species: applies only if pkmn.species matches the stone's target species.
  # For fusions: applies if either the head or body species matches; returns flags (head_applies/body_applies) 
  # so type overrides can be split correctly.
  def self.mega_context(pkmn)
    sym = held_mega_item_sym(pkmn)
    return nil unless sym

    data = ITEM_EFFECTS[sym]
    mega_species = data[:species]
    rule = data[:rule]

    sp = nil
    begin
      sp = pkmn.species
    rescue
      sp = nil
    end

    if sp == mega_species
      return { rule: rule, fusion: false, head_applies: true, body_applies: true }
    end

    if fusion_code?(pkmn)
      hs = fusion_head_species(pkmn)
      bs = fusion_body_species(pkmn)
      head_ab = (hs == mega_species)
      body_ab = (bs == mega_species)
      return nil unless head_ab || body_ab
      return { rule: rule, fusion: true, head_applies: head_ab, body_applies: body_ab }
    end

    nil
  end

  # Normalize stat keys to the canonical symbols used by this script.
  # Example: :SPATK -> :SPECIAL_ATTACK and :SPDEF -> :SPECIAL_DEFENSE.
  def self.normalize_stat_key(k)
    kk = k.to_s.upcase.to_sym
    return :SPECIAL_ATTACK  if kk == :SPATK
    return :SPECIAL_DEFENSE if kk == :SPDEF
    kk
  end

  # Apply stat changes from a rule to a base stats hash.
  # Supports additive (base_stats_add) and multiplicative (base_stats_mul) transforms.
  def self.apply_base_stat_overrides(base_stats, rule)
    bs = base_stats.dup
    add = (rule[:base_stats_add] || {})
    mul = (rule[:base_stats_mul] || {})

    [:HP, :ATTACK, :DEFENSE, :SPECIAL_ATTACK, :SPECIAL_DEFENSE, :SPEED].each do |k|
      bs[k] = (bs[k] || 0)
    end

    add.each do |k, v|
      key = normalize_stat_key(k)
      bs[key] = bs[key] + v.to_i
    end

    mul.each do |k, v|
      key = normalize_stat_key(k)
      bs[key] = (bs[key] * v.to_f).round
    end

    bs
  end

  @patched = false

  # Install runtime patches into the Pokemon class so mega effects are applied dynamically.
  # This aliases existing methods (base stats, types, ability, item=) and then layers mega logic on top via mega_context.
  def self.apply_patches!
    return if @patched
    return unless defined?(Pokemon)
    @patched = true

    if Pokemon.method_defined?(:base_stats)
      Pokemon.class_eval do
        alias __megastonesim_base_stats base_stats
        def base_stats
          bs = __megastonesim_base_stats
          ctx = MegaStoneSim.mega_context(self)
          return bs unless ctx
          MegaStoneSim.apply_base_stat_overrides(bs, ctx[:rule])
        end
      end
    elsif Pokemon.method_defined?(:baseStats)
      Pokemon.class_eval do
        alias __megastonesim_baseStats baseStats
        def baseStats
          bs = __megastonesim_baseStats
          ctx = MegaStoneSim.mega_context(self)
          return bs unless ctx
          MegaStoneSim.apply_base_stat_overrides(bs, ctx[:rule])
        end
      end
    end

    if Pokemon.method_defined?(:type1)
      Pokemon.class_eval do
        alias __megastonesim_type1 type1
        def type1
          ctx = MegaStoneSim.mega_context(self)
          return __megastonesim_type1 unless ctx
          t = ctx[:rule][:types]
          return __megastonesim_type1 unless t.is_a?(Array)
          return (t[0] || __megastonesim_type1) unless ctx[:fusion]
          return __megastonesim_type1 unless ctx[:head_applies]
          (t[0] || __megastonesim_type1)
        end
      end
    end

    if Pokemon.method_defined?(:type2)
      Pokemon.class_eval do
        alias __megastonesim_type2 type2
        def type2
          ctx = MegaStoneSim.mega_context(self)
          return __megastonesim_type2 unless ctx
          t = ctx[:rule][:types]
          return __megastonesim_type2 unless t.is_a?(Array)
          return (t[1] || __megastonesim_type2) unless ctx[:fusion]
          return __megastonesim_type2 unless ctx[:body_applies]
          (t[1] || __megastonesim_type2)
        end
      end
    end

    if Pokemon.method_defined?(:types)
      Pokemon.class_eval do
        alias __megastonesim_types types
        def types
          ctx = MegaStoneSim.mega_context(self)
          return __megastonesim_types unless ctx
          t = ctx[:rule][:types]
          return __megastonesim_types unless t.is_a?(Array)
          return t unless ctx[:fusion]
          cur = __megastonesim_types
          a = []
          a[0] = ctx[:head_applies] ? (t[0] rescue nil) : (cur[0] rescue nil)
          a[1] = ctx[:body_applies] ? (t[1] rescue nil) : (cur[1] rescue nil)
          a.compact
        end
      end
    end

    if Pokemon.method_defined?(:ability_id)
      Pokemon.class_eval do
        alias __megastonesim_ability_id ability_id
        def ability_id
          ctx = MegaStoneSim.mega_context(self)
          return __megastonesim_ability_id unless ctx
          ab = ctx[:rule][:ability]
          return __megastonesim_ability_id unless ab
          ab
        end
      end
    end

    if Pokemon.method_defined?(:item=)
      Pokemon.class_eval do
        alias __megastonesim_item_set item=
        def item=(value)
          __megastonesim_item_set(value)
          self.calc_stats if self.respond_to?(:calc_stats)
        end
      end
    end
  end
end

#===============================================================================
# 3) Bootstrap: when to run registration + patching
#===============================================================================
module MegaStoneBootstrap
  @hooked = false

  # If the game exposes GameData.kurayeggs_loadsystem, hook it to run registration + icon copying after the data load completes.
  # This is a safer "run after core data is ready" point in some Kuray/KIF builds.
  def self.try_hook_kuray!
    return if @hooked
    return unless defined?(GameData)
    return unless GameData.respond_to?(:kurayeggs_loadsystem)

    MegaStonesLog.log("Hooking GameData.kurayeggs_loadsystem...")

    begin
      sc = GameData.singleton_class
      unless sc.method_defined?(:__megastones_kurayeggs_loadsystem)
        sc.class_eval do
          alias_method :__megastones_kurayeggs_loadsystem, :kurayeggs_loadsystem
          define_method(:kurayeggs_loadsystem) do |*args|
            __megastones_kurayeggs_loadsystem(*args)
            MegaStoneItems.register_once!
            MegaStoneIcons.ensure_icons_present!
          end
        end
      end
      @hooked = true
      MegaStonesLog.log("Hook installed.")
    rescue => e
      MegaStonesLog.err(e, "try_hook_kuray!")
    end
  end

  # Periodic bootstrap entry-point (called every Graphics.update).
  # Ensures the hooks/registration/icons/patches are installed, then runs one-time helpers (debug dump, self-fusion equip).
  def self.tick!
    try_hook_kuray!
    MegaStoneItems.register_once!
    MegaStoneIcons.ensure_icons_present!
    MegaStoneIcons.install_icon_fallback_hook!
    MegaStoneSim.apply_patches!
    MegaStoneSim.dump_party_items_once!
    MegaStoneSim.auto_equip_self_fusions_once!
  rescue => e
    MegaStonesLog.err(e, "MegaStoneBootstrap.tick!")
  end
end

if defined?(Graphics) && Graphics.respond_to?(:update)
  class << Graphics
    alias __megastones_boot_update update
    # Graphics.update hook: calls the original Graphics.update, then runs MegaStoneBootstrap.tick! once per frame.
    # This makes the mod self-initializing without requiring manual calls elsewhere.
    def update(*args)
      __megastones_boot_update(*args)
      MegaStoneBootstrap.tick! rescue nil
    end
  end
end

#===============================================================================
# Mega symbol next to battler name in battle UI (PokemonDataBox)
# Uses: Graphics/Pictures/mega_sym.png
#===============================================================================

module MegaEvoUI
  # Return true if a Pokemon currently has mega effects active (i.e., mega_context is non-nil).
  # Used by the battle UI overlay to decide whether to draw the mega icon.
  def self.mega_active?(pkmn)
    begin
      return !!MegaStoneSim.mega_context(pkmn)
    rescue
      return false
    end
  end
end

if defined?(PokemonDataBox)
  class PokemonDataBox < SpriteWrapper
    # Avoid double-aliasing if you reload scripts
    unless method_defined?(:__msim_megasym_refresh)
      alias __msim_megasym_refresh refresh
      # PokemonDataBox.refresh hook: draws a small mega symbol near the battler name if mega_active? is true.
      # All drawing is wrapped in rescue so missing assets never crash a battle.
      def refresh
        __msim_megasym_refresh

        return if !@battler || !@battler.respond_to?(:pokemon)
        pkmn = @battler.pokemon
        return if !pkmn
        return unless MegaEvoUI.mega_active?(pkmn)

        begin
          # Load the repo icon: Graphics/Pictures/mega_sym.png
          icon = Bitmap.new("Graphics/Pictures/mega_sym")
          iw = icon.width
          ih = icon.height

          # Similar name offset logic used in many data boxes (prevents overlap on long names)
          nameWidth  = self.bitmap.text_size(@battler.name).width
          nameOffset = (nameWidth > 116) ? (nameWidth - 116) : 0

          base_x = (@spriteBaseX rescue 0)
          name_x = base_x + 8 - nameOffset

          # Place icon just left and a bit downward of the name
          x = name_x - iw - 2
          y = 5

          self.bitmap.blt(x, y, icon, Rect.new(0, 0, iw, ih))
          icon.dispose
        rescue
          # don't crash battle if the file is missing or draw fails
        end
      end
    end
  end
end
