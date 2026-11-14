// Dutch (Nederlands) UI dictionary. Keys are the EXACT English UI strings used
// throughout the components; values are natural Dutch translations. Built-in
// language — its display name ("Nederlands") is hardcoded in i18n.tsx.
//
// Interpolated strings use {n}-style placeholders that the component fills via
//   t('{n} duplicates removed').replace('{n}', String(n))
// so the placeholder must appear verbatim in both the key and the value.

export const nl: Record<string, string> = {
  // ── App shell / header ────────────────────────────────────────────────────
  'IPTV Gateway': 'IPTV Gateway',
  'Running version': 'Draaiende versie',
  'Workbench': 'Werkbank',
  'EPG': 'EPG',
  'Settings': 'Instellingen',
  'Theme': 'Thema',
  'System': 'Systeem',
  'Light': 'Licht',
  'Dark': 'Donker',
  'Panel': 'Paneel',
  'Sources': 'Bronnen',
  'Catalog': 'Catalogus',
  'Bouquet': 'Bouquet',
  'Connecting…': 'Verbinden…',
  'backend: {status}': 'backend: {status}',
  'ok': 'ok',
  'checking…': 'bezig…',
  'Log out': 'Uitloggen',
  '● Proxy {state}': '● Proxy {state}',
  'On': 'Aan',
  'Off': 'Uit',
  'Stream proxy ON — video is relayed through this server. Click to turn off.':
    'Streamproxy AAN — video wordt via deze server doorgegeven. Klik om uit te zetten.',
  'Stream proxy OFF — box gets the raw provider URL. Click to relay (e.g. abroad).':
    'Streamproxy UIT — de box krijgt de ruwe provider-URL. Klik om door te geven (bijv. in het buitenland).',
  '↻ Refresh Plex': '↻ Plex vernieuwen',
  'Bouquet changed — have Plex reload the guide/lineup':
    'Bouquet gewijzigd — laat Plex de gids/zenderlijst opnieuw inlezen',
  'Bouquet changed — set the Plex server/token (Settings), or scan manually in Plex':
    'Bouquet gewijzigd — stel de Plex-server/token in (Instellingen), of scan handmatig in Plex',

  // ── LoginGate ─────────────────────────────────────────────────────────────
  'Admin access is password-protected.': 'Beheertoegang is met een wachtwoord beveiligd.',
  'Password': 'Wachtwoord',
  'Incorrect password': 'Onjuist wachtwoord',
  'Too many failed logins. Try again in {n} s.': 'Te veel mislukte aanmeldpogingen. Probeer het over {n} s opnieuw.',
  'Checking…': 'Bezig met controleren…',
  'Log in': 'Inloggen',

  // ── Modal ─────────────────────────────────────────────────────────────────
  'Close': 'Sluiten',

  // ── Content-type labels (SourcesPanel TYPE_LABEL) ─────────────────────────
  'Live': 'Live',
  'Movies': 'Films',
  'Series': 'Series',
  'Radio': 'Radio',

  // ── SourcesPanel ──────────────────────────────────────────────────────────
  'Refresh all': 'Alles vernieuwen',
  'Refreshing…': 'Vernieuwen…',
  'Strip prefixes (all)': 'Prefixen strippen (alle)',
  'Stripping…': 'Strippen…',
  'Re-apply every source’s strip-prefixes to all channels on your lists (manual renames are kept)':
    'Pas de strip-prefixen van elke bron toe op alle zenders in je lijsten (handmatige hernoemingen blijven behouden)',
  'Stripped prefixes on {n} channels.': 'Prefixen gestript op {n} zenders.',
  'Last refresh: {when}': 'Laatst vernieuwd: {when}',
  'Last refresh: never': 'Laatst vernieuwd: nooit',
  'Expires: {when}': 'Verloopt: {when}',
  'Expired: {when}': 'Verlopen: {when}',
  'in {n} days': 'over {n} dagen',
  'No end date': 'Geen einddatum',
  'Expiry: refresh to fetch': 'Vervaldatum: klik Refresh om op te halen',
  'max {n} connections': 'max {n} verbindingen',
  'Clear filters': 'Filters wissen',
  'Remove all include and exclude filters of this source?': 'Alle include- en exclude-filters van deze bron verwijderen?',
  'Loading…': 'Laden…',
  'No sources yet.': 'Nog geen bronnen.',
  'disabled': 'uitgeschakeld',
  'Busy…': 'Bezig…',
  'Refresh': 'Vernieuwen',
  'Edit': 'Bewerken',
  'Delete': 'Verwijderen',
  'Edit source #{id}': 'Bron #{id} bewerken',
  'Add source': 'Bron toevoegen',
  'Name': 'Naam',
  'Kind': 'Type',
  'stalker (MAG)': 'stalker (MAG)',
  'URL': 'URL',
  'http://portal/c/ or …/portal.php': 'http://portal/c/ of …/portal.php',
  'MAC (Username)': 'MAC (gebruikersnaam)',
  'Username': 'Gebruikersnaam',
  'Stalker/MAG: enter the device MAC address here':
    'Stalker/MAG: voer hier het MAC-adres van het apparaat in',
  'EPG URL': 'EPG-URL',
  'User-Agent': 'User-Agent',
  'empty = default browser UA': 'leeg = standaard browser-UA',
  'Some providers block the default UA. E.g. VLC/3.0.20 LibVLC/3.0.20':
    'Sommige providers blokkeren de standaard-UA. Bijv. VLC/3.0.20 LibVLC/3.0.20',
  'Referer': 'Referer',
  'Live always as HLS (m3u8)': 'Live altijd als HLS (m3u8)',
  'Box gets live channels as HLS (.m3u8) even when it asks for .ts. Helps when a provider drops .ts streams every few seconds.':
    'De box krijgt live-zenders als HLS (.m3u8), ook als hij om .ts vraagt. Helpt als een provider .ts-streams steeds verbreekt.',
  'empty = none': 'leeg = geen',
  'Some portals require a Referer that matches the portal domain, e.g. http://provider.com/c/':
    'Sommige portals vereisen een Referer die overeenkomt met het portaaldomein, bijv. http://provider.com/c/',
  'Name filters': 'Naamfilters',
  'Name filters — {name}': 'Naamfilters — {name}',
  'source #{id}': 'bron #{id}',
  'Include ({n})': 'Insluiten ({n})',
  'Exclude ({n})': 'Uitsluiten ({n})',
  'Tick discovered prefixes or type tokens (prefix OR suffix, case-insensitive). Include = keep only matches (empty = keep all); Exclude = drop matches.':
    'Vink ontdekte voorvoegsels aan of typ tokens (voorvoegsel OF achtervoegsel, hoofdletterongevoelig). Insluiten = alleen overeenkomsten behouden (leeg = alles behouden); Uitsluiten = overeenkomsten verwijderen.',
  'Editing an existing source? Click “Edit” on it above first — discovered prefixes come from that source’s channels.':
    'Een bestaande bron bewerken? Klik hierboven eerst op “Bewerken” — ontdekte voorvoegsels komen uit de zenders van die bron.',
  'Strip prefixes': 'Voorvoegsels verwijderen',
  'e.g. NL; UK': 'bijv. NL; UK',
  'Leading tokens removed from a channel name when it is added to a list — e.g. "NL" turns "NL| NPO 1", "|NL|", "NL - …" into the bare name. Separate multiple tokens with ; (a token may contain spaces/commas). Case-insensitive. The name is trimmed afterwards.':
    'Voorloop-tokens die uit een zendernaam worden verwijderd zodra die aan een lijst wordt toegevoegd — bijv. "NL" maakt van "NL| NPO 1", "|NL|", "NL - …" de kale naam. Scheid meerdere tokens met ; (een token mag spaties/komma’s bevatten). Hoofdletterongevoelig. De naam wordt daarna getrimd.',
  'Strip prefixes and suffixes are removed when a channel is added to a list (the catalog keeps the original name).':
    'Voorvoegsels en achtervoegsels worden verwijderd wanneer een zender aan een lijst wordt toegevoegd (de catalogus behoudt de oorspronkelijke naam).',
  'Strip suffixes': 'Achtervoegsels verwijderen',
  'e.g. (S); rec': 'bijv. (S); rec',
  'Trailing tokens removed from a channel name when it is added to a list — e.g. "(S)" turns "HISTORY RAW (S)" into "HISTORY RAW". Separate multiple tokens with ;. Case-insensitive; decorative letters (small caps, superscript) match their plain form.':
    'Tokens aan het eind die uit een zendernaam worden verwijderd zodra die aan een lijst wordt toegevoegd — bijv. "(S)" maakt van "HISTORY RAW (S)" "HISTORY RAW". Scheid meerdere tokens met ;. Hoofdletterongevoelig; sierletters (klein kapitaal, superscript) matchen hun gewone vorm.',
  'Original name: {name}': 'Originele naam: {name}',
  'Enabled': 'Ingeschakeld',
  'Saving…': 'Opslaan…',
  'Save': 'Opslaan',
  'Add': 'Toevoegen',
  'Cancel': 'Annuleren',
  'Include filters': 'Insluitfilters',
  'Exclude filters': 'Uitsluitfilters',
  'Done': 'Klaar',
  'Ingesting…': 'Inlezen…',
  '{n} streams': '{n} streams',
  '⚠ Failed: {error}': '⚠ Mislukt: {error}',
  '✓ Done: {streams} streams': '✓ Klaar: {streams} streams',
  ', {n} groups': ', {n} groepen',
  ', {n} EPG': ', {n} EPG',

  // ── FilterEditor ──────────────────────────────────────────────────────────
  'Keep only channels whose name starts- or ends-with one of these tokens. Leave empty to keep everything.':
    'Behoud alleen zenders waarvan de naam met een van deze tokens begint of eindigt. Laat leeg om alles te behouden.',
  'Drop channels whose name starts- or ends-with one of these tokens.':
    'Verwijder zenders waarvan de naam met een van deze tokens begint of eindigt.',
  'Selected tokens': 'Geselecteerde tokens',
  'clear all': 'alles wissen',
  'Publish only these groups of the Plex bouquet to Plex/Jellyfin (M3U, XMLTV and HDHomeRun lineup). Select none to publish everything. Boxes always get their whole bouquet.':
    'Publiceer alleen deze groepen van het Plex-bouquet naar Plex/Jellyfin (M3U, XMLTV en HDHomeRun-lineup). Niets geselecteerd = alles publiceren. Boxen krijgen altijd hun hele bouquet.',
  'Bouquet for Plex / Jellyfin': 'Bouquet voor Plex / Jellyfin',
  'First enabled bouquet (default)': 'Eerste ingeschakelde bouquet (standaard)',
  'Plex and Jellyfin can’t log in, so they get this bouquet. Your boxes keep their own bouquet via their username/password. After switching, have Plex rescan.':
    'Plex en Jellyfin kunnen niet inloggen, dus zij krijgen dit bouquet. Je boxen houden hun eigen bouquet via hun gebruikersnaam/wachtwoord. Laat Plex na het wisselen opnieuw scannen.',
  'Source: {name}': 'Bron: {name}',
  'Upstream channel no longer exists': 'Kanaal bestaat niet meer bij de bron',
  'Remove': 'Verwijderen',
  'None yet.': 'Nog geen.',
  'e.g. NL|, UK:': 'bijv. NL|, UK:',
  'e.g. XXX, ADULT': 'bijv. XXX, ADULT',
  'Discovered prefixes': 'Ontdekte voorvoegsels',
  'select all': 'alles selecteren',
  'select all shown': 'alle getoonde selecteren',
  'none': 'geen',
  'Save the source and refresh it to discover prefixes.':
    'Sla de bron op en vernieuw deze om voorvoegsels te ontdekken.',
  'Discovering prefixes…': 'Voorvoegsels ontdekken…',
  'No prefixes found — refresh the source to discover them.':
    'Geen voorvoegsels gevonden — vernieuw de bron om ze te ontdekken.',
  'Search {n} prefixes…': '{n} voorvoegsels doorzoeken…',
  '{n} channels': '{n} zenders',
  'No match.': 'Geen overeenkomst.',

  // ── CatalogPanel ──────────────────────────────────────────────────────────
  '{n} channels (catalog)': '{n} zenders',
  '{n} groups': '{n} groepen',
  'Search (contains)…': 'Zoeken (bevat)…',
  'Prefix (e.g. NL:)': 'Voorvoegsel (bijv. NL:)',
  'All sources': 'Alle bronnen',
  'Only new': 'Alleen nieuw',
  '{n} selected': '{n} geselecteerd',
  'Add to': 'Toevoegen aan',
  'Target list…': 'Doellijst…',
  'Upstream group': 'Bron-groep',
  'Groups belong to the active list; target that list to pick a group':
    'Groepen horen bij de actieve lijst; selecteer die lijst om een groep te kiezen',
  'Pick a target list first': 'Kies eerst een doellijst',
  'Add {n} to {list} → {group}': '{n} toevoegen aan {list} → {group}',
  'Adding…': 'Toevoegen…',
  'Add {n} → {group}': '{n} toevoegen → {group}',
  'Mark selected as seen': 'Selectie markeren als gezien',
  'Marking…': 'Markeren…',
  '← Back to groups': '← Terug naar groepen',
  'Search: “{term}”': 'Zoeken: “{term}”',
  'Page size': 'Paginagrootte',
  '‹ Prev': '‹ Vorige',
  'Page {page} / {count}': 'Pagina {page} / {count}',
  'Next ›': 'Volgende ›',
  '{n} new groups': '{n} nieuwe groepen',
  'Mark all groups seen': 'Alle groepen als gezien markeren',
  'Pick a source to browse its groups, or type a search term for a flat channel list.':
    'Kies een bron om de groepen te bekijken, of typ een zoekterm voor een platte zenderlijst.',
  'Select all on this page': 'Alles op deze pagina selecteren',
  'Group': 'Groep',
  'Type': 'Type',
  'Source': 'Bron',
  'NEW': 'NIEUW',
  'No channels match.': 'Geen zenders gevonden.',
  'Mark this group as seen': 'Deze groep als gezien markeren',
  'No groups match.': 'Geen groepen gevonden.',
  'Pick a source to see its groups.': 'Kies een bron om de groepen te zien.',

  // ── ListPanel ─────────────────────────────────────────────────────────────
  'Download playlist as M3U': 'Afspeellijst downloaden als M3U',
  '⬇ .m3u': '⬇ .m3u',
  'Download EPG as XMLTV': 'EPG downloaden als XMLTV',
  '⬇ EPG': '⬇ EPG',
  'Pick a list…': 'Kies een lijst…',
  'Select a list to curate.': 'Selecteer een lijst om samen te stellen.',
  'New group name': 'Naam nieuwe groep',
  'Favorite': 'Favoriet',
  'Add group': 'Groep toevoegen',
  'Remove duplicate channels (same upstream URL), keeping one':
    'Dubbele zenders verwijderen (zelfde bron-URL), één behouden',
  'Dedupe': 'Ontdubbelen',
  '{n} duplicates removed': '{n} duplicaten verwijderd',
  'no duplicates found': 'geen duplicaten gevonden',
  'Suggest EPG-ids': 'EPG-id’s voorstellen',
  'Match channel names to known guide ids (tvg-id) and propose an EPG id for channels that have none':
    'Match zendernamen met bekende gids-id’s (tvg-id) en stel een EPG-id voor bij zenders die er geen hebben',
  'No EPG-id suggestions (every channel already resolves, or no good match).':
    'Geen EPG-id-suggesties (elke zender heeft er al een, of geen goede match).',
  'Set EPG-id on {n} channels.': 'EPG-id ingesteld op {n} zenders.',
  'EPG-id suggestions': 'EPG-id-suggesties',
  'Apply ({n})': 'Toepassen ({n})',
  'Applying…': 'Toepassen…',
  'Tick the channels to set the suggested guide id (tvg-id). Best matches first; review before applying.':
    'Vink de zenders aan waarvoor je de voorgestelde gids-id (tvg-id) wilt zetten. Beste matches eerst; controleer voor toepassen.',
  // ── duplicate group (swap to another quality or provider) ───────────────────
  'Replace or duplicate this group — swap channels to another quality or provider':
    'Zenders in deze groep vervangen of de groep dupliceren — naar andere kwaliteit of provider',
  'Duplicate “{name}”': '“{name}” dupliceren',
  'Replace channels in “{name}”': 'Zenders vervangen in “{name}”',
  'Where': 'Waar',
  'Where:': 'Waar:',
  'In this group': 'In deze groep',
  'Copy to a new group': 'Kopie in nieuwe groep',
  'Swap each channel in this group for a variant, in place: channel number, logo and EPG-id stay. Channels with no variant are left as they are. You can untick channels in the next step.':
    'Vervang elke zender in deze groep ter plekke door een variant: kanaalnummer, logo en EPG-id blijven. Zenders zonder variant blijven zoals ze zijn. In de volgende stap kun je zenders uitvinken.',
  'Review the {q} variant for each channel. Ticked channels are replaced in this group; unmatched ones stay as they are.':
    'Controleer de {q}-variant per zender. Aangevinkte zenders worden in deze groep vervangen; zonder match blijven ze zoals ze zijn.',
  'Replace {n} channels': '{n} zenders vervangen',
  'Strip prefixes/suffixes from the channel names in this group':
    'Voor-/achtervoegsels uit de zendernamen in deze groep verwijderen',
  'Clean names in “{name}”': 'Namen opschonen in “{name}”',
  'Strips the sources’ prefixes/suffixes — plus any extra tokens below — from the names the channels in this group show now. Manual names only change when they contain such a token. The original name stays visible.':
    'Verwijdert de voor-/achtervoegsels van de bronnen — plus eventuele extra tokens hieronder — uit de namen die de zenders in deze groep nu tonen. Zelf gekozen namen veranderen alleen als ze zo’n token bevatten. De originele naam blijft zichtbaar.',
  'Extra prefixes': 'Extra voorvoegsels',
  'Extra suffixes': 'Extra achtervoegsels',
  'Preview': 'Voorbeeld',
  'Nothing to strip — all names are already clean.': 'Niets te verwijderen — alle namen zijn al schoon.',
  'Working…': 'Bezig…',
  'Cleaned {n} channel names in “{name}”.': '{n} zendernamen opgeschoond in “{name}”.',
  'Replacing…': 'Vervangen…',
  'Replaced {n} channels in “{name}”.': '{n} zenders vervangen in “{name}”.',
  'Make a copy of this group where each channel is swapped for a variant. Channels with no variant are skipped (they stay in the original group).':
    'Maak een kopie van deze groep waarbij elke zender wordt vervangen door een variant. Zenders zonder variant worden overgeslagen (die blijven in de oorspronkelijke groep).',
  'Replace by': 'Vervangen door',
  'Replace by:': 'Vervangen door:',
  'Quality': 'Kwaliteit',
  'Provider': 'Provider',
  'Target quality': 'Doelkwaliteit',
  'Replacement provider': 'Vervangende provider',
  '(no sources)': '(geen bronnen)',
  'other provider': 'andere provider',
  'Find variants': 'Varianten zoeken',
  'Searching…': 'Zoeken…',
  'This group has no channels.': 'Deze groep heeft geen zenders.',
  'Review the {q} variant for each channel. Ticked channels go into the new group; unmatched ones are flagged and left out.':
    'Controleer de {q}-variant per zender. Aangevinkte zenders komen in de nieuwe groep; zonder match worden gemarkeerd en weggelaten.',
  '— {q} variant already on this list': '— {q}-variant staat al op deze lijst',
  '— no {q} variant found': '— geen {q}-variant gevonden',
  'Create group ({n})': 'Groep aanmaken ({n})',
  'Creating…': 'Aanmaken…',
  'Back': 'Terug',
  'Created “{name}” with {n} channels.': '“{name}” aangemaakt met {n} zenders.',
  'Sort channels by': 'Zenders sorteren op',
  'Sort:': 'Sorteren:',
  'Order channels A→Z by name': 'Zenders A→Z op naam sorteren',
  'No.': 'Nr.',
  'Order channels by channel number (lowest first; unset last)':
    'Zenders op zendernummer sorteren (laagste eerst; zonder nummer laatst)',
  '⠿ drag channels to set the numbering': '⠿ sleep zenders om de nummering in te stellen',
  'Expand all groups': 'Alle groepen uitklappen',
  'Collapse all groups': 'Alle groepen inklappen',
  '⊞ Expand all': '⊞ Alles uitklappen',
  '⊟ Collapse all': '⊟ Alles inklappen',
  'No groups or items yet.': 'Nog geen groepen of items.',
  'Expand': 'Uitklappen',
  'Collapse': 'Inklappen',
  'Confirm empty': 'Leegmaken bevestigen',
  'Remove all channels from the upstream group': 'Alle zenders uit de bron-groep verwijderen',
  '🗑 Empty': '🗑 Leegmaken',
  'Unmark favorite': 'Favoriet verwijderen',
  'Mark favorite': 'Als favoriet markeren',
  'Rename': 'Hernoemen',
  "Sort this group's channels A→Z (renumber)":
    'De zenders van deze groep A→Z sorteren (hernummeren)',
  'Remove all channels from this group (keeps the group)':
    'Alle zenders uit deze groep verwijderen (de groep blijft bestaan)',
  'Empty group (remove all its channels, keep the group)':
    'Groep leegmaken (verwijder alle zenders, behoud de groep)',
  'Delete group (its channels move to Upstream group)':
    'Groep verwijderen (de zenders verhuizen naar de bron-groep)',
  'Drag to reorder': 'Sleep om te herschikken',
  'Reorder': 'Herschikken',
  'Reorder group': 'Groep herschikken',
  'Drag to reorder groups': 'Sleep om groepen te herschikken',
  'Channel number': 'Zendernummer',
  'Display name': 'Weergavenaam',
  'Upstream: {name}': 'Bron: {name}',
  'Logo override URL': 'Logo-overschrijf-URL',
  'tvg-id (EPG)': 'tvg-id (EPG)',
  'Upstream tvg-id: {id} — empty = use that one':
    'Bron tvg-id: {id} — leeg = die gebruiken',
  'No upstream tvg-id — pick one for the guide/Plex':
    'Geen bron-tvg-id — kies er een voor de gids/Plex',
  'Remove channel from the list': 'Zender uit de lijst verwijderen',
  'Remove channel': 'Zender verwijderen',

  // ── SettingsView ──────────────────────────────────────────────────────────
  'Language': 'Taal',
  'Settings export / import': 'Instellingen exporteren / importeren',
  'Export to file': 'Naar bestand exporteren',
  'Choose import file…': 'Importbestand kiezen…',
  'sources': 'bronnen',
  'lists': 'lijsten',
  'This replaces all current sources + lists (and clears the catalog).':
    'Dit vervangt alle huidige bronnen + lijsten (en wist de catalogus).',
  'Not a valid settings file.': 'Geen geldig instellingenbestand.',
  'Not a valid JSON file.': 'Geen geldig JSON-bestand.',
  'Imported: {sources} sources, {lists} lists, {groups} groups. Refresh the sources to populate the catalog.':
    'Geïmporteerd: {sources} bronnen, {lists} lijsten, {groups} groepen. Vernieuw de bronnen om de catalogus te vullen.',
  'Importing…': 'Importeren…',
  'Replace everything': 'Alles vervangen',
  'Contains settings + sources + lists + groups — not the chosen channels. Importing replaces the entire configuration; refresh the sources afterwards.':
    'Bevat instellingen + bronnen + lijsten + groepen — niet de gekozen zenders. Importeren vervangt de volledige configuratie; vernieuw daarna de bronnen.',
  'Service settings': 'Service-instellingen',
  'Daily refresh': 'Dagelijkse verversing',
  'Time': 'Tijd',
  'Local time the service refreshes all sources + EPG.':
    'Lokale tijd waarop de service alle bronnen + EPG vernieuwt.',
  'EPG max days': 'EPG max. dagen',
  'Limit the generated guide to this many days ahead (0 = unlimited, takes everything the providers supply).':
    'Beperk de gegenereerde gids tot zoveel dagen vooruit (0 = onbeperkt, neemt alles wat de providers leveren).',
  'Stream proxy': 'Streamproxy',
  'Relay streams through this server': 'Streams via deze server doorgeven',
  'Proxy port': 'Proxypoort',
  'OFF (default): the box gets the raw provider URL — video never flows through us. ON: output URLs point back here and we relay the bytes (handy abroad; costs bandwidth/CPU). Applied live.':
    'UIT (standaard): de box krijgt de ruwe provider-URL — video loopt nooit via ons. AAN: uitvoer-URL’s wijzen terug hierheen en wij geven de bytes door (handig in het buitenland; kost bandbreedte/CPU). Direct toegepast.',
  'Fail over to another source when a channel is down':
    'Naar een andere bron overschakelen als een zender plat ligt',
  'Only while relaying: if a channel’s provider can’t be reached, try the same channel (matched by tvg-id, else exact name) from another source. A plain 302 redirect can’t fail over.':
    'Alleen bij doorgeven: als de provider van een zender onbereikbaar is, probeer dezelfde zender (op tvg-id, anders exacte naam) uit een andere bron. Een gewone 302-redirect kan niet omschakelen.',
  'Plex Live TV': 'Plex Live TV',
  'M3U + XMLTV tuner (option A)': 'M3U + XMLTV-tuner (optie A)',
  'stream via proxy (otherwise direct)': 'stream via proxy (anders rechtstreeks)',
  'In Plex → M3U tuner:': 'In Plex → M3U-tuner:',
  'XMLTV guide:': 'XMLTV-gids:',
  'HDHomeRun tuner + auto-discovery (option B, SSDP)':
    'HDHomeRun-tuner + automatische detectie (optie B, SSDP)',
  'Tuners (concurrent streams)': 'Tuners (gelijktijdige streams)',
  'Force Plex guide order via the channel-id (recommended)':
    'Plex-gidsvolgorde afdwingen via de zender-id (aanbevolen)',
  'Plex sorts its Live TV guide by the channel-id, not the name — so a name prefix can’t reorder it. This puts a zero-padded number plus the channel name in the channel-id (e.g. “01 NPO 1”) in your bouquet order, so Plex’s guide follows your order. EPG keeps working (the guide ids are re-keyed together); your box output keeps the real ids. After enabling, remove + re-add the DVR in Plex.':
    'Plex sorteert de Live TV-gids op de zender-id, niet op de naam — dus een naamvoorvoegsel kan de volgorde niet veranderen. Dit zet een nummer met voorloopnullen plus de zendernaam in de zender-id (bijv. “01 NPO 1”) in jouw bouquet-volgorde, zodat de Plex-gids jouw volgorde volgt. EPG blijft werken (de gids-ids worden samen omgezet); je box-output houdt de echte ids. Verwijder daarna de DVR in Plex en voeg die opnieuw toe.',
  'Show a provider letter in the channel name (groups by provider in Plex)':
    'Providerletter in de kanaalnaam tonen (groepeert per provider in Plex)',
  'Puts a per-provider letter in front — A = 1st source, B = 2nd, … — e.g. “A NPO 1”, “B HBO”. A leading letter is NOT stripped by Plex the way a leading number is, so Plex actually groups + sorts your channels by provider. Combine with the number for “A 018 NPO 1”.':
    'Zet een letter per provider vooraan — A = 1e bron, B = 2e, … — bijv. “A NPO 1”, “B HBO”. Een letter vooraan wordt door Plex niet gestript zoals een cijfer, dus Plex groepeert + sorteert je kanalen echt per provider. Combineer met het nummer voor “A 018 NPO 1”.',
  'Show a sort number in the channel name (forces Plex order)':
    'Sorteernummer in de kanaalnaam tonen (dwingt Plex-volgorde af)',
  'Plex usually sorts Live TV by name. This puts a zero-padded number in front — e.g. “010 NPO 1” — following your exact bouquet order (group order + channel order), so Plex ends up sorted the way you arranged it.':
    'Plex sorteert Live TV meestal op naam. Dit zet er een nummer met voorloopnullen vóór — bijv. “010 NPO 1” — in exact jouw bouquet-volgorde (groep-volgorde + kanaalvolgorde), zodat Plex net zo gesorteerd staat als jij het hebt ingedeeld.',
  'Both together give e.g. “010 Sport · NPO 1”.':
    'Allebei samen geeft bijv. “010 Sport · NPO 1”.',
  'Show group in the channel name (Plex/HDHomeRun)':
    'Groep in de kanaalnaam tonen (Plex/HDHomeRun)',
  'Plex’s HDHomeRun tuner can’t display groups, so this prefixes each channel with its group — e.g. “Sport · NPO 1” — so you can tell the provider apart. Only affects the Plex/Jellyfin output; your normal box keeps clean names.':
    'De HDHomeRun-tuner van Plex kan geen groepen tonen, dus dit zet de groep vóór elke kanaalnaam — bijv. “Sport · NPO 1” — zodat je de provider kunt onderscheiden. Raakt alleen de Plex/Jellyfin-output; je gewone box houdt schone namen.',
  'Plex finds the HDHomeRun automatically (UDP 1900), or add it manually at {url}.':
    'Plex vindt de HDHomeRun automatisch (UDP 1900), of voeg deze handmatig toe op {url}.',
  'For the guide, pick “Have an XMLTV guide on your server” and use:':
    'Kies voor de gids “Have an XMLTV guide on your server” en gebruik:',
  'Plex server (optional — for the rescan button)':
    'Plex-server (optioneel — voor de herscan-knop)',
  'Plex token (X-Plex-Token)': 'Plex-token (X-Plex-Token)',
  'Have Plex re-read its DVR guide/lineup': 'Laat Plex de DVR-gids/zenderlijst opnieuw inlezen',
  'Rescan Plex': 'Plex herscannen',
  'Plex rescan started ({dvrs} {dvrWord}).': 'Plex-herscan gestart ({dvrs} {dvrWord}).',
  'DVR': 'DVR',
  'DVRs': "DVR's",
  'Save your settings first; the button has Plex re-read the guide + channels after a bouquet change. Find the token via Plex (X-Plex-Token).':
    'Sla eerst je instellingen op; de knop laat Plex de gids + zenders opnieuw inlezen na een bouquetwijziging. Vind de token via Plex (X-Plex-Token).',
  'Save settings': 'Instellingen opslaan',
  'Saved ✓': 'Opgeslagen ✓',
  'Output lists': 'Uitvoerlijsten',
  'List': 'Lijst',
  'Select list': 'Lijst selecteren',
  '(unnamed)': '(naamloos)',
  ' — default': ' — standaard',
  ' (disabled)': ' (uitgeschakeld)',
  '➕ New list…': '➕ Nieuwe lijst…',
  'Credentials are optional: a list with an empty username becomes the default the box resolves to when it sends no/unknown login.':
    'Inloggegevens zijn optioneel: een lijst met een lege gebruikersnaam wordt de standaard waarop de box terugvalt wanneer deze geen/onbekende login stuurt.',
  'Username (optional)': 'Gebruikersnaam (optioneel)',
  'Password (optional)': 'Wachtwoord (optioneel)',
  'Add list': 'Lijst toevoegen',
  'Confirm delete': 'Verwijderen bevestigen',

  // ── EpgView ───────────────────────────────────────────────────────────────
  'Own list': 'Eigen lijst',
  'Search live channels…': 'Live zenders zoeken…',
  'No channels with a tvg-id match.': 'Geen zenders met een passende tvg-id.',
  'Pick a channel to see its guide.': 'Kies een zender om de gids te zien.',
  'Loading guide…': 'Gids laden…',
  'Select list…': 'Lijst selecteren…',
  'Re-fetch EPG for the channels now on the list':
    'EPG opnieuw ophalen voor de zenders die nu op de lijst staan',
  '⟳ Update EPG': '⟳ EPG bijwerken',
  'Reload': 'Opnieuw laden',
  'Updating EPG… (may take a while)': 'EPG bijwerken… (kan even duren)',
  'Select a list to see its curated guide.':
    'Selecteer een lijst om de samengestelde gids te zien.',
  'No programmes for this list.': 'Geen programma’s voor deze lijst.',
  'Channel': 'Zender',
  'No programmes.': 'Geen programma’s.',
  'NOW': 'NU',
  ' · NOW': ' · NU',
  // Media Servers tab
  'Media Servers': 'Media Servers',
  'Base URL': 'Basis-URL',
  'Used to build the tuner URLs below. Leave empty to use whatever host the request came in on.':
    'Wordt gebruikt om de tuner-URL’s hieronder te bouwen. Leeg laten om de host van het request zelf te gebruiken.',
  'Base URL must start with http:// or https:// (or be empty).':
    'Basis-URL moet met http:// of https:// beginnen (of leeg zijn).',
  'Channel filter': 'Zenderfilter',
  'Publish only these groups on the M3U, XMLTV and HDHomeRun lineup. Select none to publish everything (current behaviour).':
    'Publiceer alleen deze groepen op de M3U, XMLTV en HDHomeRun-lineup. Niets selecteren = alles publiceren (huidig gedrag).',
  'Publish all groups': 'Alle groepen publiceren',
  'No groups yet — pick channels onto the default list first.':
    'Nog geen groepen — kies eerst zenders op de standaardlijst.',
  '(no group)': '(geen groep)',
  'Published now: {ch} channels — {real} with real EPG, {dummy} dummy.':
    'Nu gepubliceerd: {ch} zenders — {real} met echte EPG, {dummy} dummy.',
  'Dummy EPG': 'Dummy EPG',
  'Fill channels without real guide data with dummy programmes':
    'Vul zenders zonder echte gidsdata met dummy-programma’s',
  'Stops Plex/Jellyfin showing “Unknown airing”. Channels with real EPG are left untouched.':
    'Voorkomt “Unknown airing” in Plex/Jellyfin. Zenders met echte EPG blijven ongewijzigd.',
  'Block length (minutes)': 'Bloklengte (minuten)',
  'Window: hours back': 'Venster: uren terug',
  'Window: hours ahead': 'Venster: uren vooruit',
  'Plex / Jellyfin tuners': 'Plex / Jellyfin-tuners',
  'Enable M3U + XMLTV tuner (Jellyfin, or Plex “M3U tuner”)':
    'M3U + XMLTV-tuner inschakelen (Jellyfin, of Plex “M3U tuner”)',
  'Enable HDHomeRun tuner + auto-discovery (Plex, SSDP)':
    'HDHomeRun-tuner + auto-detectie inschakelen (Plex, SSDP)',
  'Note: the gateway does not pool upstream connections — every playing channel is one connection to the provider, across all media servers. The provider’s max-connections is the real limit.':
    'Let op: de gateway deelt geen upstream-verbindingen — elke spelende zender is één verbinding met de provider, over alle media servers heen. De max-connecties van de provider is de echte limiet.',
  'Tuner URLs': 'Tuner-URL’s',
  'Tuner (discover.json)': 'Tuner (discover.json)',
  'Guide (XMLTV)': 'Gids (XMLTV)',
  'M3U tuner (playlist.m3u)': 'M3U-tuner (playlist.m3u)',
  'HDHomeRun DeviceID:': 'HDHomeRun DeviceID:',
  'New tuner ID (Plex forgets old numbering)': 'Nieuw tuner-ID (Plex vergeet oude nummering)',
  'Use when Plex keeps the wrong channel order after re-adding: this gives the tuner a new DeviceID so Plex sees a brand-new device and re-imports the lineup fresh. Afterwards, remove the DVR in Plex and add it again.':
    'Gebruik dit als Plex na opnieuw toevoegen de verkeerde volgorde blijft houden: dit geeft de tuner een nieuw DeviceID zodat Plex een gloednieuw apparaat ziet en de lineup vers inleest. Verwijder daarna de DVR in Plex en voeg die opnieuw toe.',
  'New DeviceID: {id} — now remove and re-add the DVR in Plex.':
    'Nieuw DeviceID: {id} — verwijder nu de DVR in Plex en voeg die opnieuw toe.',
  'Copy': 'Kopiëren',
  'Copied ✓': 'Gekopieerd ✓',
  'Copy to clipboard': 'Kopiëren naar klembord',
  'Plex server (optional)': 'Plex-server (optioneel)',
  'Plex/Jellyfin tuners, the channel filter and dummy EPG live in the “Media Servers” tab.':
    'Plex/Jellyfin-tuners, het zenderfilter en dummy EPG staan in het tabblad “Media Servers”.',
  // ── Quality probe (measure a channel in all qualities) ────────────────────
  'Measure quality': 'Kwaliteit meten',
  'No log lines yet.': 'Nog geen logregels.',
  'Clear view': 'Scherm leegmaken',
  'Resume': 'Doorgaan',
  'Pause': 'Pauze',
  'Only problems': 'Alleen problemen',
  'Filter (e.g. timeshift, EPG, failed)…': 'Filter (bv. timeshift, EPG, failed)…',
  'Log': 'Log',
  'Extra EPG sources': 'Extra EPG-bronnen',
  'One XMLTV address per line (.xml or .xml.gz), e.g. a country guide. Channels are matched by name or tvg-id and get these programmes instead of the provider’s own guide, unless that source has “Own EPG before the extra EPG source”. Channel ids and numbers stay the same. Fetched with every refresh or “Update EPG”. The first line wins when guides overlap.':
    'Eén XMLTV-adres per regel (.xml of .xml.gz), bijvoorbeeld een landengids. Zenders worden gekoppeld op naam of tvg-id en krijgen deze programma’s in plaats van de eigen gids van de provider, tenzij die bron “Eigen EPG vóór de extra EPG-bron” heeft. Zender-id’s en -nummers blijven gelijk. Wordt opgehaald bij elke verversing of “EPG bijwerken”. Bij overlap wint de bovenste regel.',
  'Own EPG before the extra EPG source': 'Eigen EPG vóór de extra EPG-bron',
  'Use this provider’s own guide for its channels whenever it has data; the extra EPG source (Settings) then only fills gaps. Off: the extra EPG source goes first.':
    'Gebruik de eigen gids van deze provider zodra die gegevens heeft; de extra EPG-bron (Instellingen) vult dan alleen gaten. Uit: de extra EPG-bron gaat voor.',
  'Catch-up: replay the past {n} days on boxes that support it':
    'Terugkijken: de afgelopen {n} dagen opnieuw bekijken op boxen die dat ondersteunen',
  'Measure quality: all variants of this channel': 'Kwaliteit meten: alle varianten van deze zender',
  'Measure quality: {name}': 'Kwaliteit meten: {name}',
  'Also other providers': 'Ook andere providers',
  'Seconds per variant': 'Seconden per variant',
  'Stop': 'Stop',
  'Measure again': 'Opnieuw meten',
  'Each variant is pulled from the provider for a few seconds, one at a time. If someone is watching on the same account, a measurement can fail or interrupt them.':
    'Elke variant wordt een paar seconden bij de provider opgehaald, één voor één. Kijkt er iemand via hetzelfde account, dan kan een meting mislukken of die kijker onderbreken.',
  'Looking for variants…': 'Varianten zoeken…',
  'No variants found.': 'Geen varianten gevonden.',
  'Variant': 'Variant',
  'Video': 'Video',
  'Resolution': 'Resolutie',
  'fps': 'fps',
  'Bitrate': 'Bitrate',
  'Audio': 'Audio',
  'Start': 'Start',
  'Real time': 'Realtime',
  'Media seconds received per second; below 1 the player will buffer':
    'Ontvangen seconden beeld per seconde; onder 1 gaat de speler bufferen',
  'Status': 'Status',
  'current': 'huidig',
  'on list': 'in lijst',
  'Highest bitrate': 'Hoogste bitrate',
  'matched by tvg-id': 'gevonden via tvg-id',
  'measuring…': 'meten…',
  'waiting': 'wacht',
  'failed': 'mislukt',
  'Use this': 'Gebruik deze',
  'Not replaced (already on the list, or another content type).':
    'Niet vervangen (staat al in de lijst, of ander inhoudstype).',
  'possibly upscaled': 'mogelijk opgeschaald',
  'slower than real time': 'trager dan realtime',
  'slow start': 'trage start',
  'stream ended early': 'stream stopte voortijdig',
  'no video found in the stream': 'geen video gevonden in de stream',
  // ── Bouquet-wide renumber ─────────────────────────────────────────────────
  'Renumber bouquet': 'Bouquet hernummeren',
  'Number all channels across all groups: each group starts on a new hundred (a thousand for groups over 99 channels)':
    'Alle zenders over alle groepen nummeren: elke groep begint op een nieuw honderdtal (duizendtal bij groepen met meer dan 99 zenders)',
  'Groups in the order shown, channels in their current order. Each group starts on a new hundred; a group with more than 99 channels starts on a new thousand.':
    'Groepen in de getoonde volgorde, zenders in hun huidige volgorde. Elke groep begint op een nieuw honderdtal; een groep met meer dan 99 zenders begint op een nieuw duizendtal.',
  'Channels': 'Zenders',
  'Numbers': 'Nummers',
  'Renumber {n} channels': '{n} zenders hernummeren',
  '{n} channels renumbered': '{n} zenders hernummerd',

  // ── confirmations / log ───────────────────────────────────────────────────
  'Delete source “{name}”? All its channels are removed from every bouquet.':
    'Bron “{name}” verwijderen? Al haar zenders worden uit elk bouquet verwijderd.',
  'Delete group': 'Groep verwijderen',
  'Download': 'Downloaden',
  'Only replace channels with quality': 'Alleen kanalen vervangen met kwaliteit',
  '(all qualities)': '(alle kwaliteiten)',
  'No channel in this group has quality {q}.': 'Geen kanaal in deze groep heeft kwaliteit {q}.',
  'Only channels with quality {q}: {n} other channels are left as they are.':
    'Alleen kanalen met kwaliteit {q}: {n} andere kanalen blijven zoals ze zijn.',
  'Bouquet changed — set the Plex server/token (Media Servers), or scan manually in Plex':
    'Bouquet gewijzigd — stel de Plex-server/token in (Mediaservers), of scan handmatig in Plex',
  'The Plex bouquet changed — update the channels and guide in Plex':
    'Het Plex-bouquet is gewijzigd — werk de kanalen en de gids in Plex bij',
  'Register the HDHomeRun tuner and a DVR with this guide in Plex and map all channels':
    'Meld de HDHomeRun-tuner en een DVR met deze gids aan in Plex en koppel alle kanalen',
  'Setting up…': 'Bezig met instellen…',
  'Set up in Plex': 'Instellen in Plex',
  '“Set up in Plex” needs the HDHomeRun tuner enabled and saved. It re-uses a tuner or DVR Plex already has, so running it again is safe.':
    '“Instellen in Plex” vraagt een ingeschakelde en opgeslagen HDHomeRun-tuner. Een tuner of DVR die Plex al kent wordt hergebruikt, dus opnieuw uitvoeren kan geen kwaad.',
  'Media servers: allowed clients': 'Mediaservers: toegestane clients',
  'The Plex/Jellyfin tuner and HDHomeRun addresses have no login. One IP address per line (e.g. your Plex server), or a prefix ending in a dot such as 192.168.1. for a whole network. Empty = every client.':
    'De Plex/Jellyfin-tuner en de HDHomeRun-adressen hebben geen login. Eén IP-adres per regel (bijv. je Plex-server), of een voorvoegsel dat op een punt eindigt zoals 192.168.1. voor een heel netwerk. Leeg = elke client.',

  // ── Mirror bouquets ───────────────────────────────────────────────────────
  'Mirror of': 'Spiegel van',
  '(none — own channels)': '(geen — eigen kanalen)',
  'Mirrored by {names}, so this bouquet can’t mirror another one itself.':
    'Gespiegeld door {names}, dus dit bouquet kan zelf geen ander bouquet spiegelen.',
  'A mirror always shows the channels of the chosen bouquet (read-only) and plays them with its own provider account.':
    'Een spiegel toont altijd de kanalen van het gekozen bouquet (alleen-lezen) en speelt ze af met een eigen provideraccount.',
  'Server URL': 'Server-URL',
  'Server URL for {source}': 'Server-URL voor {source}',
  'Username for {source}': 'Gebruikersnaam voor {source}',
  'Password for {source}': 'Wachtwoord voor {source}',
  '(same as the source)': '(zelfde als de bron)',
  'Only for another account at the same provider; the server URL must point to that same provider.':
    'Alleen voor een ander account bij dezelfde provider; de server-URL moet naar diezelfde provider wijzen.',
  'This bouquet mirrors “{name}”: its channels come from there, it only plays them with its own provider account.':
    'Dit bouquet spiegelt “{name}”: de kanalen komen daarvandaan, het speelt ze alleen af met een eigen provideraccount.',
  'Open “{name}”': '“{name}” openen',
  'Its box login, provider accounts and on/off switch are under Settings → Output lists.':
    'De box-login, provideraccounts en aan/uit-schakelaar staan onder Instellingen → Uitvoerlijsten.',
}
