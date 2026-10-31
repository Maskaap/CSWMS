// Floor-screen translations (counting, My tasks, quick undo, worker menu).
// English is the reference. Afrikaans, isiZulu and isiXhosa were written for CSWMS and
// should be read once by a first-language speaker on site before go-live (see docs/STAFF_GUIDE.md).
// Management screens stay in English.
export type Lang = 'en' | 'af' | 'zu' | 'xh';
export const LANGS: { id: Lang; label: string }[] = [
  { id: 'en', label: 'English' }, { id: 'af', label: 'Afrikaans' }, { id: 'zu', label: 'isiZulu' }, { id: 'xh', label: 'isiXhosa' },
];

const en = {
  today: 'Today', my_tasks: 'My tasks', receive: 'Receive', withdraw: 'Withdraw', look_up: 'Look up', tools: 'Tools', count: 'Count',
  good_morning: 'Good morning', good_afternoon: 'Good afternoon', good_evening: 'Good evening',
  nothing_today: 'Nothing waiting for you right now.',
  counts_to_do: 'Counts to do', start_counting: 'Start counting', continue_counting: 'Continue counting', recounts: 'recounts asked',
  items_counted: 'counted', overdue: 'Overdue', due: 'Due', cycle_count: 'Cycle count', full_count: 'Stocktake',
  tools_held: 'Tools you are holding', due_back: 'Due back', transfers_in: 'Transfers to receive', approvals_waiting: 'Approvals waiting for you',
  unread: 'unread messages', undo_recent: 'Recent — you can still undo', undo: 'Undo', undo_reason: 'What was wrong?',
  undo_reason_hint: 'e.g. wrong item scanned, wrong quantity', undo_done: 'Undone. Stock is back as it was.', seconds_left: 'left',
  bin: 'Bin', bins: 'bins', next_bin: 'Next bin', prev_bin: 'Previous bin', done_with_bin: 'Done with this bin',
  bin_empty: 'Bin is empty', bin_empty_confirm: 'Nothing left uncounted in this bin will be recorded as 0. Continue?',
  scan_item: 'Scan an item', scan_or_type: 'Scan the barcode, or type the code', scan_bin: 'Scan the bin label to start',
  type_qty: 'Type a quantity', add: 'Add', counted: 'Counted', not_counted: 'Not counted yet', total: 'Total',
  each_scan_adds: 'Each scan adds 1. A box barcode adds the whole box.',
  saved: 'Saved', waiting_to_send: 'waiting to send', sending: 'Sending…', all_sent: 'All counts sent',
  offline_counting: 'Offline — keep counting. Counts are kept on this phone and sent when the signal returns.',
  not_in_bin: 'Not expected in this bin — added as an extra item.', unknown_code: 'Code not found. Try again or type the product code.',
  counting_closed: 'Counting is closed for this stocktake.', progress: 'Progress', finished: 'All bins done — thank you!',
  tell_supervisor: 'Tell your supervisor you have finished.', ready_offline: 'Ready to count without signal',
  download_failed: 'Could not download the count list. Connect to the internet once, then try again.',
  sound: 'Sound', big_text: 'Large text', language: 'Language', settings: 'My settings', back: 'Back',
  count_sheet: 'Count list', last_counts: 'My last counts', remove: 'Remove', in_bin: 'in this bin',
  not_sent: 'Could not be sent', not_sent_help: 'Tell your supervisor the item and quantity.',
  training_banner: 'TRAINING WAREHOUSE — practice only. Nothing here affects real stock.',
} as const;
export type Key = keyof typeof en;

const af: Record<Key, string> = {
  today: 'Vandag', my_tasks: 'My take', receive: 'Ontvang', withdraw: 'Uitreik', look_up: 'Soek', tools: 'Gereedskap', count: 'Tel',
  good_morning: 'Goeiemôre', good_afternoon: 'Goeiemiddag', good_evening: 'Goeienaand',
  nothing_today: 'Niks wag nou vir jou nie.',
  counts_to_do: 'Tellings om te doen', start_counting: 'Begin tel', continue_counting: 'Gaan voort met tel', recounts: 'hertellings gevra',
  items_counted: 'getel', overdue: 'Agterstallig', due: 'Sperdatum', cycle_count: 'Siklustelling', full_count: 'Voorraadopname',
  tools_held: 'Gereedskap by jou', due_back: 'Terug teen', transfers_in: 'Oordragte om te ontvang', approvals_waiting: 'Goedkeurings wat op jou wag',
  unread: 'ongeleesde boodskappe', undo_recent: 'Onlangs — jy kan dit nog ongedaan maak', undo: 'Ongedaan maak', undo_reason: 'Wat was verkeerd?',
  undo_reason_hint: 'bv. verkeerde item geskandeer, verkeerde hoeveelheid', undo_done: 'Ongedaan gemaak. Die voorraad is terug soos dit was.', seconds_left: 'oor',
  bin: 'Bak', bins: 'bakke', next_bin: 'Volgende bak', prev_bin: 'Vorige bak', done_with_bin: 'Klaar met hierdie bak',
  bin_empty: 'Bak is leeg', bin_empty_confirm: 'Alles wat nog nie in hierdie bak getel is nie, word as 0 aangeteken. Gaan voort?',
  scan_item: 'Skandeer ’n item', scan_or_type: 'Skandeer die strepieskode, of tik die kode', scan_bin: 'Skandeer die bak se etiket om te begin',
  type_qty: 'Tik ’n hoeveelheid', add: 'Voeg by', counted: 'Getel', not_counted: 'Nog nie getel nie', total: 'Totaal',
  each_scan_adds: 'Elke skandering tel 1 by. ’n Doos se strepieskode tel die hele doos by.',
  saved: 'Gestoor', waiting_to_send: 'wag om gestuur te word', sending: 'Stuur…', all_sent: 'Alle tellings gestuur',
  offline_counting: 'Geen sein nie — hou aan tel. Tellings bly op hierdie foon en word gestuur sodra die sein terug is.',
  not_in_bin: 'Nie in hierdie bak verwag nie — as ekstra item bygevoeg.', unknown_code: 'Kode nie gevind nie. Probeer weer of tik die produkkode.',
  counting_closed: 'Tel is gesluit vir hierdie opname.', progress: 'Vordering', finished: 'Alle bakke klaar — dankie!',
  tell_supervisor: 'Sê vir jou toesighouer jy is klaar.', ready_offline: 'Gereed om sonder sein te tel',
  download_failed: 'Kon nie die tellys aflaai nie. Koppel een keer aan die internet en probeer weer.',
  sound: 'Klank', big_text: 'Groot teks', language: 'Taal', settings: 'My instellings', back: 'Terug',
  count_sheet: 'Tellys', last_counts: 'My laaste tellings', remove: 'Verwyder', in_bin: 'in hierdie bak',
  not_sent: 'Kon nie gestuur word nie', not_sent_help: 'Sê vir jou toesighouer die item en hoeveelheid.',
  training_banner: 'OPLEIDINGSPAKHUIS — net om te oefen. Niks hier raak die regte voorraad nie.',
};

const zu: Record<Key, string> = {
  today: 'Namuhla', my_tasks: 'Imisebenzi yami', receive: 'Yamukela', withdraw: 'Khipha', look_up: 'Bheka', tools: 'Amathuluzi', count: 'Bala',
  good_morning: 'Sawubona — sekuseni', good_afternoon: 'Sawubona — ntambama', good_evening: 'Sawubona — kusihlwa',
  nothing_today: 'Akukho okulindile manje.',
  counts_to_do: 'Ukubala okumele kwenziwe', start_counting: 'Qala ukubala', continue_counting: 'Qhubeka ubala', recounts: 'ukubala kabusha okucelwe',
  items_counted: 'kubaliwe', overdue: 'Sekwedlule isikhathi', due: 'Kufanele kuqedwe', cycle_count: 'Ukubala kwansuku zonke', full_count: 'Ukubalwa kwesitoko',
  tools_held: 'Amathuluzi aphethwe nguwe', due_back: 'Kufanele abuyiswe', transfers_in: 'Okudluliselwe okufanele kwamukelwe', approvals_waiting: 'Izimvume ezikulindile',
  unread: 'imilayezo engafundiwe', undo_recent: 'Okwenziwe muva — usengakuhlehlisa', undo: 'Hlehlisa', undo_reason: 'Yini ebingalungile?',
  undo_reason_hint: 'isib. kuskenwe into engafanele, inani elingalungile', undo_done: 'Kuhlehlisiwe. Isitoko sibuyile njengoba sasinjalo.', seconds_left: 'esele',
  bin: 'Ibhini', bins: 'amabhini', next_bin: 'Ibhini elilandelayo', prev_bin: 'Ibhini elidlule', done_with_bin: 'Ngiqedile ngaleli bhini',
  bin_empty: 'Ibhini alinalutho', bin_empty_confirm: 'Konke okungakabalwa kuleli bhini kuzobhalwa njengo-0. Uqhubeke?',
  scan_item: 'Skena into', scan_or_type: 'Skena ibhakhodi, noma ubhale ikhodi', scan_bin: 'Skena ilebula lebhini ukuze uqale',
  type_qty: 'Bhala inani', add: 'Engeza', counted: 'Kubaliwe', not_counted: 'Akukabalwa', total: 'Isamba',
  each_scan_adds: 'Ukuskena ngakunye kwengeza okungu-1. Ibhakhodi yebhokisi yengeza ibhokisi lonke.',
  saved: 'Kugciniwe', waiting_to_send: 'kulinde ukuthunyelwa', sending: 'Kuyathunyelwa…', all_sent: 'Konke ukubala kuthunyelwe',
  offline_counting: 'Ayikho isiginali — qhubeka ubala. Ukubala kugcinwa kule foni futhi kuthunyelwa uma isiginali ibuya.',
  not_in_bin: 'Bekungalindelekile kuleli bhini — kungezwe njengento eyengeziwe.', unknown_code: 'Ikhodi ayitholakali. Zama futhi noma ubhale ikhodi yomkhiqizo.',
  counting_closed: 'Ukubala kuvaliwe kulokhu kubalwa kwesitoko.', progress: 'Inqubekela phambili', finished: 'Wonke amabhini aqediwe — siyabonga!',
  tell_supervisor: 'Tshela umphathi wakho ukuthi uqedile.', ready_offline: 'Kulungele ukubala ngaphandle kwesiginali',
  download_failed: 'Akukwazekanga ukulanda uhlu lokubala. Xhuma ku-inthanethi kanye, bese uzama futhi.',
  sound: 'Umsindo', big_text: 'Umbhalo omkhulu', language: 'Ulimi', settings: 'Izilungiselelo zami', back: 'Buyela emuva',
  count_sheet: 'Uhlu lokubala', last_counts: 'Ukubala kwami kwakamuva', remove: 'Susa', in_bin: 'kuleli bhini',
  not_sent: 'Akukwazekanga ukuthunyelwa', not_sent_help: 'Tshela umphathi wakho into nenani.',
  training_banner: 'INDAWO YOKUQEQESHA — eyokuzijwayeza kuphela. Akukho lapha okuthinta isitoko sangempela.',
};

const xh: Record<Key, string> = {
  today: 'Namhlanje', my_tasks: 'Imisebenzi yam', receive: 'Yamkela', withdraw: 'Khupha', look_up: 'Jonga', tools: 'Izixhobo', count: 'Bala',
  good_morning: 'Molo — kusasa', good_afternoon: 'Molo — emva kwemini', good_evening: 'Molo — ngorhatya',
  nothing_today: 'Akukho nto ikulindileyo ngoku.',
  counts_to_do: 'Ukubala ekufuneka kwenziwe', start_counting: 'Qalisa ukubala', continue_counting: 'Qhubeka ubala', recounts: 'ukubala kwakhona okuceliweyo',
  items_counted: 'kubaliwe', overdue: 'Lidlulile ixesha', due: 'Mayigqitywe', cycle_count: 'Ukubala kwemihla ngemihla', full_count: 'Ukubalwa kwesitokhwe',
  tools_held: 'Izixhobo oziphetheyo', due_back: 'Mazibuyiswe', transfers_in: 'Okudluliselweyo ekufuneka kwamkelwe', approvals_waiting: 'Iimvume ezikulindileyo',
  unread: 'imiyalezo engafundwanga', undo_recent: 'Okwenziwe kutshanje — usenako ukukurhoxisa', undo: 'Rhoxisa', undo_reason: 'Yintoni ebingachanekanga?',
  undo_reason_hint: 'umz. kuskenwe into engeyiyo, inani elingachanekanga', undo_done: 'Kurhoxisiwe. Isitokhwe sibuyile njengoko sasinjalo.', seconds_left: 'eseleyo',
  bin: 'Ibhini', bins: 'iibhini', next_bin: 'Ibhini elandelayo', prev_bin: 'Ibhini edlulileyo', done_with_bin: 'Ndigqibile ngale bhini',
  bin_empty: 'Ibhini ayinanto', bin_empty_confirm: 'Yonke into engekabalwa kule bhini iya kubhalwa njengo-0. Uyaqhubeka?',
  scan_item: 'Skena into', scan_or_type: 'Skena ibhakhowudi, okanye uchwetheze ikhowudi', scan_bin: 'Skena ileyibhile yebhini ukuze uqalise',
  type_qty: 'Chwetheza inani', add: 'Yongeza', counted: 'Kubaliwe', not_counted: 'Akukabalwa', total: 'Iyonke',
  each_scan_adds: 'Ukuskena nganye kongeza enye. Ibhakhowudi yebhokisi yongeza ibhokisi yonke.',
  saved: 'Kugciniwe', waiting_to_send: 'kulindele ukuthunyelwa', sending: 'Kuyathunyelwa…', all_sent: 'Konke ukubala kuthunyelwe',
  offline_counting: 'Akukho mqondiso — qhubeka ubala. Ukubala kugcinwa kule fowuni kwaye kuthunyelwa xa umqondiso ubuya.',
  not_in_bin: 'Ibingalindelekanga kule bhini — yongezwe njengento eyongezelelweyo.', unknown_code: 'Ikhowudi ayifumaneki. Zama kwakhona okanye uchwetheze ikhowudi yemveliso.',
  counting_closed: 'Ukubala kuvaliwe kolu balo lwesitokhwe.', progress: 'Inkqubela', finished: 'Zonke iibhini zigqityiwe — enkosi!',
  tell_supervisor: 'Xelela umphathi wakho ukuba ugqibile.', ready_offline: 'Kulungele ukubala ngaphandle komqondiso',
  download_failed: 'Akukwazekanga ukukhuphela uluhlu lokubala. Qhagamshela kwi-intanethi kanye, uze uzame kwakhona.',
  sound: 'Isandi', big_text: 'Umbhalo omkhulu', language: 'Ulwimi', settings: 'Iisetingi zam', back: 'Buyela umva',
  count_sheet: 'Uluhlu lokubala', last_counts: 'Ukubala kwam kwakutshanje', remove: 'Susa', in_bin: 'kule bhini',
  not_sent: 'Akukwazekanga ukuthunyelwa', not_sent_help: 'Xelela umphathi wakho into nenani.',
  training_banner: 'INDAWO YOQEQESHO — yokuziqhelisa kuphela. Akukho nto apha ichaphazela isitokhwe sokwenyani.',
};

const DICTS: Record<Lang, Record<Key, string>> = { en, af, zu, xh };

export function translator(lang: string | null | undefined) {
  const d = DICTS[(lang as Lang) in DICTS ? (lang as Lang) : 'en'];
  return (k: Key) => d[k] ?? en[k];
}

export function greeting(t: (k: Key) => string, now = new Date()): string {
  const h = Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', hour: 'numeric', hour12: false }).format(now));
  return t(h < 12 ? 'good_morning' : h < 17 ? 'good_afternoon' : 'good_evening');
}
