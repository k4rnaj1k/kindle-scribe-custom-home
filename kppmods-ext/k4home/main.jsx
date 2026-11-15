// k4 Home: replaces the stock Home content (kppmods `home` registry) with a
// library dashboard: BOOKS with covers, NOTEBOOKS, ARTICLES and UNCATEGORIZED
// lists, a header illustration (assets/vyper.webp, shipped as PNG) and a
// shortcut to the ReCalendar planner. The title, header image, collections and
// the Obsidian buttons are set with manifest options (libraryOptions below;
// documented in docs/install.md).
//
// Data sources (all through read-only sqlite3 calls, extension.exec):
// - Books, articles, uncategorized items and the calendar: /var/local/cc.db.
//   They open with appmgrd's reader route, the path verified on the device
//   (docs/kpp-notes.md).
// - Notebooks: /var/local/ksdk.content.db, the notebook SDK's store (Nodes =
//   notebooks and folders, NodeRelations = folder membership). The stock
//   NotebookService stays silent after a KPP restart until the Notebooks tab
//   has been opened, so it is not used for listing. Opening reuses
//   NotebookUtils.executeNotebookAction(OPEN_ACTION, ActionSourceId.NotebookDetails,
//   {contentUuid}, item); module ids 505/506 are for firmware 5.16.6.1 only,
//   elsewhere this falls back to the Notebooks tab.
import { useEffect, useRef, useState } from 'react';
import { DeviceEventEmitter, View } from 'react-native';
import { KindleProvider, Text, Image, ScrollView } from 'react-kindle';
import { useExtension } from '@kppmods/react';
import { HEADINGS } from './headings.gen.js';

// Stock KPP registers this native host; registering it again is an error.
const NativeButton = 'KPPUnifiedButton';
const NOTEBOOKS_ROUTE = 'app://com.lab126.KPPMainApp/?view=KPP_NOTEBOOK';
const LIBRARY_ROUTE = 'app://com.lab126.KPPMainApp/?view=KPP_LIBRARY';
const READER_ROUTE = 'app://com.lab126.booklet.reader';
const CC_DB = '/var/local/cc.db';
// Option notebookDb points elsewhere for testing (the emulator's store is empty).
const NOTEBOOK_DB = '/var/local/ksdk.content.db';
// Each list loads up to LIST_LIMIT items, most recently used first, and pages
// through them locally.
const LIST_LIMIT = 100;
const BOOKS_PER_PAGE = 5;
const NOTEBOOKS_PER_PAGE = 5;
const ARTICLES_PER_PAGE = 5;
// Fixed list row height: a vertical scroller without a fixed height takes up
// the rest of the page and pushes the sections below it off screen.
const ROW_HEIGHT = 44;
// Events the stock HomeView subscribes to (HomeView.componentDidMount, 5.16.6.1).
const LIBRARY_REFRESH_EVENTS = [
  'HomeLoad',
  'SafeHomeLoad',
  'RefreshHome',
  'ModifiedCardForHome',
  'ModifiedItemInsideCard',
  'homeAppNavigation'
];
const LIBRARY_POLL_MS = 30000;
// Retry delay after a failed reload, and how long a query waits for a lock.
const LIBRARY_RETRY_MS = 5000;
const DB_BUSY_TIMEOUT_MS = 5000;
// One swipe can report several scroll events, and a page change can report
// one more while the new rows lay out: turn at most one page per gesture.
const PAGE_TURN_COOLDOWN_MS = 800;
// Tap feedback stays up this long at most (e.g. when the reader shows an error).
const OPEN_FEEDBACK_MS = 10000;
// Refresh events this soon after a tap come from leaving Home, not returning.
const OPEN_EVENT_GRACE_MS = 2000;
// Time for the tapped item to repaint before the app launch freezes the display.
const OPEN_PAINT_DELAY_MS = 400;
// How long a notice (e.g. the collection editor failing) stays on screen.
const NOTICE_MS = 8000;
// Row "send to Obsidian" (kppmods-ext/k4sync): renders the article/notebook
// to PDF and uploads it to the vault inbox. Sends run one at a time; the row
// shows the state, and the result for SEND_RESULT_MS.
const K4SYNC = '/mnt/us/k4sync/k4sync.sh';
const SEND_TIMEOUT_S = 900;
const SEND_RESULT_MS = 15000;
const SEND_NOTES = {
  queued: 'Waiting to send...',
  sending: 'Sending to Obsidian...',
  sent: 'Sent to Obsidian',
  failed: 'Send failed (see k4sync.log)'
};
// Collection names and the calendar title come from manifest options
// (booksCollection, articlesCollection, calendarTitle). A collection option is
// a name or a list of names, matched case-insensitively; "*" means every book
// except scripts and crash reports. A missing collection is not an error: the
// section says so and lists the collections that exist.
const DEFAULT_BOOKS_COLLECTION = 'reading';
// Header: the title is the pre-rendered assets/heading-title.png unless option
// `title` (drawn in a firmware font, `titleSize` layout units) or `titleImage`
// is set. The image on the right is `headerImage` ("" hides it). Image options
// take a path inside the extension (assets/...) or an absolute device path
// (/mnt/us/...); sizes are layout units (about 1.8 device pixels each).
const DEFAULT_TITLE_SIZE = 44;
const DEFAULT_HEADER_IMAGE = 'assets/vyper.png';
const DEFAULT_HEADER_IMAGE_SIZE = [260, 149];
const DEFAULT_ARTICLES_COLLECTION = 'articles';
const DEFAULT_CALENDAR_TITLE = 'ReCalendar';
// Module ids are per-firmware Metro registrations: 505 NotebookUtils, 506
// ActionService + ActionSourceId.
const STOCK_MODULES = { '5.16.6.1': { utils: 505, actionSource: 506 } };
const FIELD = '\u001f';

// --------------------------------------------------------------------------
// Library (cc.db, ksdk.content.db)

function sql(text) {
  return text.replace(/\s+/g, ' ').trim();
}

function quote(text) {
  return "'" + String(text).replace(/'/g, "''") + "'";
}

// Rows of: uuid, title, author, percent, thumbnail, location.
const ITEM_COLUMNS = `e.p_uuid, e.p_titles_0_nominal, ifnull(e.p_credits_0_name_collation, ''),
  ifnull(e.p_percentFinished, -1), ifnull(e.p_thumbnail, ''), e.p_location`;
const NOT_SYSTEM_ITEM = `ifnull(e.p_mimeType, '') not in ('text/x-shellscript', 'text/plain')
  and e.p_titles_0_nominal not like 'KPPMainAppV2%'`;
function nameList(names) {
  return '(' + names.map(quote).join(', ') + ')';
}
function collectionMembers(names) {
  return `select c.i_member_uuid from Collections c
    join Entries col on col.p_uuid = c.i_collection_uuid
    where col.p_type = 'Collection' and col.p_titles_0_nominal collate nocase in ${nameList(names)}`;
}
function collectionSql(names, limit) {
  const members = names.indexOf('*') >= 0
    ? `e.p_type = 'Entry:Item' and e.p_isVisibleInHome = 1 and ${NOT_SYSTEM_ITEM}`
    : `e.p_uuid in (${collectionMembers(names)})`;
  return sql(`select ${ITEM_COLUMNS} from Entries e
    where ${members} and e.p_location is not null
    order by e.p_lastAccess desc limit ${limit}`);
}

// Books and documents that belong to no collection (scripts and crash reports
// excluded).
const UNCATEGORIZED_SQL = sql(`select ${ITEM_COLUMNS} from Entries e
  where e.p_type = 'Entry:Item' and e.p_isVisibleInHome = 1 and e.p_location is not null
    and ifnull(e.p_collectionCount, 0) = 0
    and e.p_uuid not in (select i_member_uuid from Collections)
    and ${NOT_SYSTEM_ITEM}
  order by e.p_lastAccess desc limit ${LIST_LIMIT}`);

// The downloaded copy of the planner (a cloud-only copy has no location).
function calendarSql(title) {
  return sql(`select ${ITEM_COLUMNS} from Entries e
    where e.p_type = 'Entry:Item' and e.p_location is not null
      and e.p_titles_0_nominal = ${quote(title)} collate nocase
    order by e.p_lastAccess desc limit 1`);
}

// Rows of: uuid, title, parent folder title ('' at the top level), page count.
const NOTEBOOK_SQL = sql(`select n.uuid,
    ifnull(json_extract(n.additional_data, '$.title'), n.title_collation),
    ifnull(p.title_collation, ''),
    ifnull(json_extract(n.additional_data, '$.total_page'), -1)
  from Nodes n
  left join NodeRelations r on r.target_uuid = n.uuid and r.relation_type = 'FOLDER'
  left join Nodes p on p.uuid = r.source_uuid and p.node_type = 'FOLDER'
  where n.node_type = 'STANDALONE_NOTEBOOK'
    and ifnull(json_extract(n.additional_data, '$.delete_state'), 0) = 0
  order by max(n.last_access_time, n.last_modified_time) desc limit ${LIST_LIMIT}`);

// A collection option: "name", ["name", ...] or "*".
function collectionNames(value, fallback) {
  const list = (Array.isArray(value) ? value : [value]).map((name) => String(name || '').trim()).filter(Boolean);
  return list.length ? list : [fallback];
}

const SECTIONS = ['books', 'calendar', 'notebooks', 'articles', 'uncategorized'];

function libraryOptions(extension) {
  const options = extension.options || {};
  const hidden = Array.isArray(options.hideSections) ? options.hideSections.map((name) => String(name).toLowerCase()) : [];
  return {
    books: collectionNames(options.booksCollection, DEFAULT_BOOKS_COLLECTION),
    articles: collectionNames(options.articlesCollection, DEFAULT_ARTICLES_COLLECTION),
    // Sections to leave out: any of SECTIONS.
    show: SECTIONS.reduce((shown, name) => ({ ...shown, [name]: hidden.indexOf(name) < 0 }), {}),
    calendar: options.calendarTitle || DEFAULT_CALENDAR_TITLE,
    notebookDb: options.notebookDb || NOTEBOOK_DB,
    title: typeof options.title === 'string' ? options.title : '',
    titleSize: Number(options.titleSize) || DEFAULT_TITLE_SIZE,
    titleImage: options.titleImage || '',
    titleImageSize: size(options.titleImageWidth, options.titleImageHeight, [300, 60]),
    headerImage: typeof options.headerImage === 'string' ? options.headerImage : DEFAULT_HEADER_IMAGE,
    headerImageSize: size(options.headerImageWidth, options.headerImageHeight, DEFAULT_HEADER_IMAGE_SIZE),
    // Upload buttons on NOTEBOOKS/ARTICLES rows; needs k4sync on the device.
    sendToObsidian: options.sendToObsidian !== false,
    k4sync: options.k4syncScript || K4SYNC
  };
}

function size(width, height, fallback) {
  return { width: Number(width) || fallback[0], height: Number(height) || fallback[1] };
}

// Image option -> source: absolute device paths as file:// URIs, anything else
// relative to the extension package.
function imageSource(extension, path) {
  if (/^[a-z]+:\/\//.test(path)) return path;
  return path[0] === '/' ? 'file://' + path : extension.asset(path);
}

function parseFields(stdout) {
  return (stdout || '')
    .split('\n')
    .filter((line) => line.indexOf(FIELD) >= 0)
    .map((line) => line.split(FIELD));
}

function parseItems(stdout) {
  return parseFields(stdout).map(([uuid, title, author, percent, thumbnail, location]) => ({
    uuid,
    title,
    author,
    percent: Number(percent),
    thumbnail,
    location
  }));
}

function parseNotebooks(stdout) {
  return parseFields(stdout).map(([uuid, title, folder, pages]) => ({
    uuid,
    title: title || 'Untitled notebook',
    folder,
    pages: Number(pages)
  }));
}

// Rows of: uuid, title of the first named collection that exists (none for "*").
function collectionEntrySql(names) {
  return sql(`select p_uuid, p_titles_0_nominal from Entries
    where p_type = 'Collection' and p_titles_0_nominal collate nocase in ${nameList(names)} limit 1`);
}

// Rows of: title of every collection (for "no such collection" hints), with an
// empty second column so parseFields keeps the rows.
const COLLECTIONS_SQL = sql(`select p_titles_0_nominal, '' from Entries
  where p_type = 'Collection' order by p_titles_0_nominal collate nocase`);

const EMPTY_LIBRARY = {
  books: [],
  articles: [],
  uncategorized: [],
  notebooks: [],
  calendar: null,
  booksCollection: null,
  collections: [],
  // Per-section query errors (one failing query does not hide the others).
  errors: {}
};

function useLibrary(extension) {
  const [state, setState] = useState({ status: 'loading', error: '', ...EMPTY_LIBRARY });
  // Lets callers refresh right after a change (e.g. a deleted article).
  const reloadRef = useRef(() => {});
  useEffect(() => {
    let alive = true;
    async function load() {
      // The reader and the Library write these databases; wait for their locks
      // instead of failing with "database is locked".
      const query = (db, statement) =>
        extension.exec(
          ['/usr/bin/sqlite3', '-readonly', '-cmd', `.timeout ${DB_BUSY_TIMEOUT_MS}`, '-separator', FIELD, db, statement],
          { timeout: 20 }
        );
      const names = libraryOptions(extension);
      const statements = [
        ['books', CC_DB, collectionSql(names.books, LIST_LIMIT)],
        ['articles', CC_DB, collectionSql(names.articles, LIST_LIMIT)],
        ['uncategorized', CC_DB, UNCATEGORIZED_SQL],
        ['calendar', CC_DB, calendarSql(names.calendar)],
        ['notebooks', names.notebookDb, NOTEBOOK_SQL],
        ['booksCollection', CC_DB, collectionEntrySql(names.books)],
        ['collections', CC_DB, COLLECTIONS_SQL]
      ].filter(([key]) => names.show[key] !== false);
      // One at a time: the broker keeps 32 command records and may evict a
      // finished one before its result has been read ("Command result
      // unavailable") when several are in flight. A failing query only empties
      // its own section; the load fails only when every query failed.
      const out = {};
      const errors = {};
      for (const [key, db, statement] of statements) {
        try {
          const result = await query(db, statement);
          if (result.exitCode !== 0) throw new Error((result.stderr || 'sqlite3 failed').trim());
          out[key] = result.stdout || '';
        } catch (error) {
          errors[key] = String((error && error.message) || error);
          extension.log(key + ' query failed: ' + errors[key]);
        }
      }
      const failed = Object.keys(errors);
      if (failed.length && failed.length === statements.length) throw new Error(errors[failed[0]]);
      const [booksCollection] = parseFields(out.booksCollection).map(([uuid, title]) => ({ uuid, title }));
      return {
        books: parseItems(out.books),
        articles: parseItems(out.articles),
        uncategorized: parseItems(out.uncategorized),
        calendar: parseItems(out.calendar)[0] || null,
        notebooks: parseNotebooks(out.notebooks),
        booksCollection: booksCollection || null,
        collections: parseFields(out.collections).map(([title]) => title),
        errors
      };
    }
    // Home stays mounted while other views are shown, so reload when the stock
    // Home is refreshed or navigated to, and on a slow timer for anything else
    // (e.g. collection edits, new notebooks). Only changed results re-render:
    // every repaint flashes the e-ink panel.
    let signature = '';
    let loading = false;
    let retry = null;
    function reload() {
      if (loading) return;
      loading = true;
      clearTimeout(retry);
      load()
        .then((data) => {
          const next = JSON.stringify(data);
          if (alive && next !== signature) {
            signature = next;
            setState({ status: 'ready', error: '', ...data });
          }
        })
        .catch((error) => {
          if (!alive) return;
          // Keep showing the last good lists through a transient failure and
          // try again soon; only an initial failure is shown.
          if (!signature) setState({ status: 'error', error: String(error.message || error), ...EMPTY_LIBRARY });
          retry = setTimeout(reload, LIBRARY_RETRY_MS);
        })
        .then(() => {
          loading = false;
        });
    }
    reloadRef.current = reload;
    reload();
    const subscriptions = LIBRARY_REFRESH_EVENTS.map((name) => DeviceEventEmitter.addListener(name, reload));
    const timer = setInterval(reload, LIBRARY_POLL_MS);
    return () => {
      alive = false;
      clearInterval(timer);
      clearTimeout(retry);
      subscriptions.forEach((subscription) => subscription.remove());
    };
  }, []);
  return { ...state, reload: () => reloadRef.current() };
}

// Queue of "send to Obsidian" requests: k4sync.sh send-item per item, one at
// a time (sends share k4sync's work files). Returns the per-key state
// (queued / sending / sent / failed) and send(key, target), where target is
// an article's file path or a notebook's uuid.
function useSender(extension) {
  const [states, setStates] = useState({});
  const current = useRef({});
  const queue = useRef(Promise.resolve());
  const set = (key, value) => {
    const next = { ...current.current };
    if (value) next[key] = value;
    else delete next[key];
    current.current = next;
    setStates(next);
  };
  const send = (key, target) => {
    const state = current.current[key];
    if (state === 'queued' || state === 'sending') return;
    set(key, 'queued');
    queue.current = queue.current.then(() => {
      set(key, 'sending');
      return extension
        .exec(['/bin/sh', libraryOptions(extension).k4sync, 'send-item', '--quiet', target], { timeout: SEND_TIMEOUT_S })
        .then((result) => {
          if (result.exitCode !== 0) {
            extension.log('send failed: ' + ((result.stdout || '') + (result.stderr || '')).trim().slice(-300));
          }
          return result.exitCode === 0;
        })
        .catch((error) => {
          extension.log('send failed: ' + error);
          return false;
        })
        .then((ok) => {
          set(key, ok ? 'sent' : 'failed');
          setTimeout(() => {
            if (current.current[key] === 'sent' || current.current[key] === 'failed') set(key, null);
          }, SEND_RESULT_MS);
        });
    });
  };
  return { noteFor: (key) => SEND_NOTES[states[key]] || null, isSending: (key) => !!states[key], send };
}

// The reader parses its start request as a java.net.URI: a raw path with
// spaces, '#', ',' or non-ASCII characters fails with "URI Syntax" (an error
// alert), so encode each path segment.
function readerUri(location) {
  return READER_ROUTE + location.split('/').map(encodeURIComponent).join('/');
}

function openBook(extension, item) {
  // Same LIPC request the Library makes to start the reader on a file.
  extension
    .exec(['/usr/bin/lipc-set-prop', 'com.lab126.appmgrd', 'start', readerUri(item.location)])
    .catch((error) => extension.log('open book failed: ' + error));
}

function progressText(percent) {
  if (!(percent >= 0)) return '';
  if (percent < 0.5) return 'New';
  if (percent >= 99.5) return 'Finished';
  return Math.round(percent) + '% read';
}

function knownAuthor(author) {
  return author && author !== 'Unknown' ? author : '';
}

function isCover(path) {
  // cc.db holds "0" until the Library has generated a thumbnail.
  return Boolean(path) && path.charAt(0) === '/';
}

// --------------------------------------------------------------------------
// Notebooks (stock notebook actions)

// Extension code is not evaluated inside a Metro module, so `global` is not in
// scope; Metro's require lives on the real global object.
function stockRequire(id) {
  const root = typeof globalThis !== 'undefined' ? globalThis : (0, eval)('this');
  return root.__r(id);
}

function openNotebook(extension, notebook) {
  const ids = STOCK_MODULES[extension.firmware];
  if (ids) {
    try {
      const utilsModule = stockRequire(ids.utils);
      const sourceModule = stockRequire(ids.actionSource);
      const utils = utilsModule && utilsModule.NotebookUtils;
      const source = sourceModule && sourceModule.ActionSourceId;
      if (utils && typeof utils.executeNotebookAction === 'function' && source && source.NotebookDetails) {
        // The action looks the notebook up by uuid; the item mirrors the
        // provider's library item fields.
        utils.executeNotebookAction(
          utilsModule.OPEN_ACTION || 'com.amazon.notebooks.actions.open',
          source.NotebookDetails,
          { contentUuid: notebook.uuid },
          { uuid: notebook.uuid, contentUuid: notebook.uuid, title: notebook.title, type: 'STANDALONE_NOTEBOOK' }
        );
        return;
      }
      extension.log('stock notebook modules have an unexpected shape; using the Notebooks tab');
    } catch (error) {
      extension.log('open notebook failed: ' + error);
    }
  }
  extension.navigate(NOTEBOOKS_ROUTE);
}

// --------------------------------------------------------------------------
// Stock Library actions (what an item's or collection's details sheet offers)

// "Add or remove items" of a collection: the middleware shows
// AddOrRemoveToCollectionModal and saves the picked items.
const SET_COLLECTION_ITEMS = 'com.amazon.library.actions.set_collection_items';
// "Add to collection" of an item: shows the stock collection picker.
const SET_ITEM_COLLECTIONS = 'com.amazon.library.actions.set_item_collections';
// Article delete, preferred first: "Permanently delete" removes the item from
// the device and the Amazon cloud; "Delete this document" (device only) is the
// fallback for items with no cloud copy (sideloaded). Both confirm first.
const DELETE_ARTICLE_ACTIONS = [
  'com.amazon.library.actions.permanently_delete_item',
  'com.amazon.library.actions.delete_this_document'
];
// Where the Library offers these actions; the first source whose action list
// contains the action is used.
const LIBRARY_ACTION_SOURCES = ['ItemDetails', 'ItemCover', 'OverflowMenu', 'LibraryHeader'];

// Runs a stock Library action on one item through ActionService (module 506),
// so its middleware (modal, confirmation) behaves as in the Library. actionIds
// is one id or a preference list. Resolves to '' when an action started, else
// to the reason none did; onDone runs when it has finished (saved, deleted or
// cancelled).
async function runLibraryAction(extension, actionIds, item, onDone) {
  const ids = STOCK_MODULES[extension.firmware];
  if (!ids) return 'unsupported firmware ' + extension.firmware;
  if (!item) return 'not found';
  const actions = stockRequire(ids.actionSource);
  const service = actions && actions.ActionService && actions.ActionService.getInstance();
  if (!service || typeof service.GetActions !== 'function') return 'ActionService not found';
  // Same request shape as the Library: the context is {uuid}; the native
  // handlers reject anything else with "WrongParameters".
  const context = { uuid: item.uuid };
  for (const actionId of [].concat(actionIds)) {
    for (const name of LIBRARY_ACTION_SOURCES) {
      const source = actions.ActionSourceId[name];
      const available = source ? service.GetActions(source, context) || [] : [];
      const action = available.find((candidate) => candidate && candidate.id === actionId);
      if (action) {
        service
          .ExecuteAction(source, action, [item], context)
          .catch((error) => extension.log(actionId + ' failed: ' + error))
          .then(() => onDone && onDone());
        return '';
      }
    }
  }
  return 'not offered for this item';
}

// --------------------------------------------------------------------------
// UI

function Pressable({ label, onPress, style, children }) {
  return (
    <NativeButton
      accessibilityRole="button"
      accessibilityLabel={label}
      type={0}
      active={false}
      onClicked={onPress}
      style={style}
    >
      {children}
    </NativeButton>
  );
}

// Headings pre-rendered in Monocraft / JetBrains Mono (tools/render_headings.py);
// KPP text can only use firmware fonts.
function HeadingImage({ name }) {
  const extension = useExtension();
  const heading = HEADINGS[name];
  return (
    <Image
      source={extension.asset(heading.path)}
      accessibilityLabel={heading.label}
      style={{ width: heading.width, height: heading.height }}
    />
  );
}

// Page title: a custom image, a text title in a firmware font, or the
// pre-rendered default.
function PageTitle({ options }) {
  const extension = useExtension();
  if (options.titleImage) {
    return (
      <Image
        source={imageSource(extension, options.titleImage)}
        accessibilityLabel={options.title || HEADINGS.title.label}
        style={options.titleImageSize}
      />
    );
  }
  if (options.title && options.title !== HEADINGS.title.label) {
    return (
      <Text size={options.titleSize} numberOfLines={1} style={styles.titleText}>
        {options.title}
      </Text>
    );
  }
  return <HeadingImage name="title" />;
}

function SectionHeader({ title, onAdd, addLabel, children }) {
  const key = title.toLowerCase();
  return (
    <View style={styles.sectionHeader}>
      {HEADINGS[key] ? (
        <HeadingImage name={key} />
      ) : (
        <Text size={24} style={styles.sectionTitle}>
          {title}
        </Text>
      )}
      <View style={styles.headerActions}>
        {children}
        {onAdd ? (
          <Pressable label={addLabel} onPress={onAdd} style={styles.add}>
            <Text size={40} style={styles.addGlyph}>
              +
            </Text>
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}

// Local paging over an already loaded list; the page is clamped when the list
// shrinks.
function usePager(items, perPage) {
  const [requested, setRequested] = useState(0);
  const pages = Math.max(1, Math.ceil(items.length / perPage));
  const page = Math.min(requested, pages - 1);
  return {
    page,
    pages,
    perPage,
    total: items.length,
    visible: items.slice(page * perPage, (page + 1) * perPage),
    turn: (next) => setRequested(Math.max(0, Math.min(pages - 1, next)))
  };
}

// "1-5 of 23  ‹ ›" section pager; arrows grey out at the ends.
function PageControls({ pager, label }) {
  const { page, pages, perPage, total, turn } = pager;
  if (pages <= 1) return null;
  const first = page * perPage + 1;
  const last = Math.min(total, first + perPage - 1);
  return (
    <View style={styles.pager}>
      <Text size={20} style={styles.pagerText}>
        {first}-{last} of {total}
      </Text>
      <Pressable label={'Previous ' + label} onPress={() => turn(page - 1)} style={styles.add}>
        <Text size={40} style={[styles.addGlyph, page === 0 && styles.disabled]}>
          {'‹'}
        </Text>
      </Pressable>
      <Pressable label={'Next ' + label} onPress={() => turn(page + 1)} style={styles.add}>
        <Text size={40} style={[styles.addGlyph, page === pages - 1 && styles.disabled]}>
          {'›'}
        </Text>
      </Pressable>
    </View>
  );
}

// Native paginated scroller showing one page of a pager: swipes and page keys
// arrive as onForward/onBackward and turn whole pages (no smooth scrolling,
// which ghosts on e-ink).
function PagedScroll({ pager, horizontal = false, style, contentContainerStyle, children }) {
  const lastTurn = useRef(Date.now());
  const turnBy = (delta) => {
    const now = Date.now();
    if (now - lastTurn.current < PAGE_TURN_COOLDOWN_MS) return;
    lastTurn.current = now;
    pager.turn(pager.page + delta);
  };
  return (
    <ScrollView
      mode="paginated"
      horizontal={horizontal}
      offset={0}
      onForward={() => turnBy(1)}
      onBackward={() => turnBy(-1)}
      style={style}
      contentContainerStyle={contentContainerStyle}
    >
      {children}
    </ScrollView>
  );
}

// A page of list rows that turns with left/right swipes (vertical swipes stay
// with the page scroller) as well as the header arrows. A horizontal scroller
// does not constrain its content's width, so the list width is measured.
function PagedList({ pager, children }) {
  const [width, setWidth] = useState(0);
  return (
    <View style={listViewport(pager)} onLayout={(event) => setWidth(event.nativeEvent.layout.width)}>
      {width ? (
        <PagedScroll pager={pager} horizontal style={listViewport(pager)} contentContainerStyle={{ width }}>
          {children}
        </PagedScroll>
      ) : null}
    </View>
  );
}

// Tap feedback. Starting the reader or a notebook takes a few seconds, so the
// tapped item turns black at once (the e-ink "flash") and shows "Opening..."
// until Home is shown again or OPEN_FEEDBACK_MS passes (e.g. after an error).
function useOpening() {
  const [opening, setOpening] = useState(null);
  useEffect(() => {
    if (!opening) return undefined;
    const started = Date.now();
    const clear = () => setOpening(null);
    const timer = setTimeout(clear, OPEN_FEEDBACK_MS);
    // Leaving Home can emit these too; only a return to Home clears.
    const subscriptions = LIBRARY_REFRESH_EVENTS.map((name) =>
      DeviceEventEmitter.addListener(name, () => {
        if (Date.now() - started > OPEN_EVENT_GRACE_MS) clear();
      })
    );
    return () => {
      clearTimeout(timer);
      subscriptions.forEach((subscription) => subscription.remove());
    };
  }, [opening]);
  return {
    isOpening: (key) => opening === key,
    launch: (key, action) => {
      if (opening) return;
      setOpening(key);
      // The window manager pauses the display as soon as an app launch starts:
      // let the highlighted frame reach the panel first.
      setTimeout(action, OPEN_PAINT_DELAY_MS);
    }
  };
}

// "Opening..." with cycling dots, in a fixed width so the row does not shift.
function OpeningLabel({ size = 20, style }) {
  const [dots, setDots] = useState(1);
  useEffect(() => {
    const timer = setInterval(() => setDots((count) => (count % 3) + 1), 600);
    return () => clearInterval(timer);
  }, []);
  return (
    <Text size={size} numberOfLines={1} style={[styles.openingLabel, style]}>
      {'Opening' + '...'.slice(0, dots)}
    </Text>
  );
}

// Black block that replaces a cover while it opens. (An absolutely positioned
// overlay does not show: the native image view draws above its siblings.)
function OpeningCover({ style }) {
  return (
    <View style={[style, styles.openingCover]}>
      <OpeningLabel size={22} style={styles.inverted} />
    </View>
  );
}

function Empty({ children }) {
  return (
    <Text size={22} style={styles.empty}>
      {children}
    </Text>
  );
}

function BookTile({ book, busy, onPress }) {
  const percent = book.percent >= 0 ? Math.max(0, Math.min(100, book.percent)) : 0;
  return (
    <Pressable label={book.title} onPress={onPress} style={styles.book}>
      {busy ? (
        <OpeningCover style={styles.cover} />
      ) : isCover(book.thumbnail) ? (
        <Image source={'file://' + book.thumbnail} accessibilityLabel="" style={styles.cover} />
      ) : (
        <View style={[styles.cover, styles.coverPlaceholder]}>
          <Text size={22} numberOfLines={4} style={styles.placeholderTitle}>
            {book.title}
          </Text>
        </View>
      )}
      <View style={styles.progressTrack}>
        <View style={[styles.progressFill, { width: `${percent}%` }]} />
      </View>
      <Text size={22} numberOfLines={1} style={styles.bookTitle}>
        {book.title}
      </Text>
      {knownAuthor(book.author) ? (
        <Text size={20} numberOfLines={1}>
          {knownAuthor(book.author)}
        </Text>
      ) : null}
      <Text size={20} numberOfLines={1}>
        {progressText(book.percent)}
      </Text>
    </Pressable>
  );
}

// Compact single-line row: optional icon, title, then detail on the right, and
// optional action buttons (their own tap targets, not nested in the row's).
// While opening, the row is inverted and the detail becomes "Opening...";
// `note` (e.g. a send status) replaces the detail.
function ItemRow({ title, detail, note, icon, busy, onPress, actions }) {
  return (
    <View style={[styles.compactRow, busy && styles.busyRow]}>
      <Pressable label={title} onPress={onPress} style={styles.rowMain}>
        {icon && !busy ? <Image source={icon} accessibilityLabel="" style={styles.rowIcon} /> : null}
        <Text size={24} numberOfLines={1} style={[styles.compactTitle, busy && styles.inverted]}>
          {title}
        </Text>
        {busy ? (
          <OpeningLabel style={[styles.compactDetail, styles.inverted]} />
        ) : note || detail ? (
          <Text size={20} numberOfLines={1} style={styles.compactDetail}>
            {note || detail}
          </Text>
        ) : null}
      </Pressable>
      {!busy
        ? (actions || []).filter(Boolean).map((action) => (
            <Pressable key={action.label} label={action.label} onPress={action.onPress} style={styles.rowAction}>
              <Image source={action.icon} accessibilityLabel="" style={styles.rowActionIcon} />
            </Pressable>
          ))
        : null}
    </View>
  );
}

// A paged list keeps one page of height (or fewer rows when the list is
// short), so turning to a shorter last page does not shift what follows.
function listViewport(pager) {
  return { height: Math.min(pager.perPage, pager.total) * ROW_HEIGHT };
}

function itemDetail(item) {
  return [knownAuthor(item.author), progressText(item.percent)].filter(Boolean).join(' · ');
}

// CALENDAR column to the right of BOOKS: the planner's cover, large.
function CalendarSection({ item, busy, onPress }) {
  const extension = useExtension();
  return (
    <View style={styles.calendarColumn}>
      <SectionHeader title="CALENDAR" />
      <Pressable label={'Open ' + item.title} onPress={onPress} style={styles.calendar}>
        {busy ? (
          <OpeningCover style={styles.calendarCover} />
        ) : (
          <Image
            source={isCover(item.thumbnail) ? 'file://' + item.thumbnail : extension.asset('assets/calendar.svg')}
            accessibilityLabel=""
            style={styles.calendarCover}
          />
        )}
      </Pressable>
    </View>
  );
}

// What an empty collection section says: why it is empty and how to fix it.
function collectionHint(kind, names, option, library) {
  if (library.errors[kind]) return `Could not read ${kind}: ${library.errors[kind]}`;
  if (names.indexOf('*') >= 0) return `No ${kind} yet.`;
  const known = library.collections.map((title) => title.toLowerCase());
  const label = names.map((name) => `"${name}"`).join(' or ');
  if (library.collections.length && !names.some((name) => known.indexOf(name.toLowerCase()) >= 0)) {
    return `No collection named ${label} (option ${option}). Collections on this Kindle: ${library.collections.join(', ')}.`;
  }
  if (!library.collections.length && !library.errors.collections) {
    return `Create a collection named ${label} in the Library, or set option ${option}.`;
  }
  return `Add ${kind} to the ${label} collection.`;
}

function K4Home() {
  const extension = useExtension();
  const library = useLibrary(extension);
  const notebookIcon = extension.asset('assets/notebook.svg');
  const options = libraryOptions(extension);
  // The calendar column takes one book slot, and is not listed twice.
  const calendar = library.calendar;
  const bookItems = calendar ? library.books.filter((book) => book.uuid !== calendar.uuid) : library.books;
  const books = usePager(bookItems, calendar ? BOOKS_PER_PAGE - 1 : BOOKS_PER_PAGE);
  const notebooks = usePager(library.notebooks, NOTEBOOKS_PER_PAGE);
  const articles = usePager(library.articles, ARTICLES_PER_PAGE);
  const ready = library.status === 'ready';
  const { isOpening, launch } = useOpening();
  // A short note in the affected section when a stock action is unavailable.
  const [notice, setNotice] = useState(null);
  useEffect(() => {
    if (!notice) return undefined;
    const timer = setTimeout(() => setNotice(null), NOTICE_MS);
    return () => clearTimeout(timer);
  }, [notice]);
  const noticeFor = (section) => (notice && notice.section === section ? <Empty>{notice.text}</Empty> : null);
  // Runs a stock Library action; the lists reload once it has finished.
  // Resolves to whether it started; if not, says why in `section`.
  const libraryAction = (section, what, actionIds, item) =>
    runLibraryAction(extension, actionIds, item, library.reload)
      .catch((error) => String(error.message || error))
      .then((reason) => {
        if (!reason) return true;
        extension.log(actionIds + ' unavailable: ' + reason);
        setNotice({ section, text: `Could not ${what} (${reason}).` });
        return false;
      });
  // BOOKS "+": add or remove items of the books collection in place, falling
  // back to the Library.
  const editBooks = () => {
    const collection = library.booksCollection && { ...library.booksCollection, type: 'Collection' };
    if (!collection) {
      extension.navigate(LIBRARY_ROUTE);
      return;
    }
    libraryAction('books', `edit "${collection.title}"`, SET_COLLECTION_ITEMS, collection).then((started) => {
      if (!started) extension.navigate(LIBRARY_ROUTE);
    });
  };
  const deleteIcon = extension.asset('assets/delete.svg');
  const addToCollectionIcon = extension.asset('assets/add-to-collection.svg');
  const sendIcon = extension.asset('assets/send.svg');
  const sender = useSender(extension);
  // null when Obsidian sending is off (ItemRow skips it).
  const sendAction = (key, title, target) =>
    options.sendToObsidian
      ? { label: 'Send ' + title + ' to Obsidian', icon: sendIcon, onPress: () => sender.send(key, target) }
      : null;
  const [viewportHeight, setViewportHeight] = useState(0);
  // The page scroller is controlled: its scrollbar is drawn from the offset
  // prop, and a fixed offset would also snap the page back on every render.
  // Native scrolls report contentOffset; feed it back.
  const [pageOffset, setPageOffset] = useState(0);
  const trackPageOffset = (event) => {
    const y = event.nativeEvent && event.nativeEvent.contentOffset && event.nativeEvent.contentOffset.y;
    if (typeof y === 'number') setPageOffset(Math.max(0, Math.round(y)));
  };
  return (
    <KindleProvider firmware={extension.firmware} presentation="unified" fontScale={1}>
      {/* The page is taller than the screen: a native paginated scroller moves
          it a screen at a time (no smooth scrolling, which ghosts on e-ink). */}
      <View style={styles.pageScroller} onLayout={(event) => setViewportHeight(event.nativeEvent.layout.height)}>
      {viewportHeight ? (
      <ScrollView
        mode="paginated"
        offset={pageOffset}
        onScroll={trackPageOffset}
        style={{ height: viewportHeight }}
        contentContainerStyle={styles.page}
      >
        <View style={styles.header}>
          <PageTitle options={options} />
          {options.headerImage ? (
            <View style={styles.meme}>
              <Image
                source={imageSource(extension, options.headerImage)}
                accessibilityLabel=""
                style={options.headerImageSize}
              />
            </View>
          ) : null}
        </View>

        {library.status === 'error' ? <Empty>Library unavailable: {library.error}</Empty> : null}
        <View style={styles.booksSection}>
          {options.show.books ? (
          <View style={styles.booksArea}>
            <SectionHeader title="BOOKS" addLabel={`Add or remove "${options.books.join(', ')}" items`} onAdd={editBooks}>
              <PageControls pager={books} label="books" />
            </SectionHeader>
            {noticeFor('books')}
            {ready && !bookItems.length ? (
              <Empty>{collectionHint('books', options.books, 'booksCollection', library)}</Empty>
            ) : null}
            {books.visible.length ? (
              <PagedScroll pager={books} horizontal style={styles.bookScroller} contentContainerStyle={styles.bookRow}>
                {books.visible.map((book) => (
                  <BookTile
                    key={book.uuid}
                    book={book}
                    busy={isOpening('book:' + book.uuid)}
                    onPress={() => launch('book:' + book.uuid, () => openBook(extension, book))}
                  />
                ))}
              </PagedScroll>
            ) : null}
          </View>
          ) : null}
          {calendar && options.show.calendar ? (
            <CalendarSection
              item={calendar}
              busy={isOpening('calendar')}
              onPress={() => launch('calendar', () => openBook(extension, calendar))}
            />
          ) : null}
        </View>

        {options.show.notebooks ? (
          <SectionHeader title="NOTEBOOKS" addLabel="Open Notebooks" onAdd={() => extension.navigate(NOTEBOOKS_ROUTE)}>
            <PageControls pager={notebooks} label="notebooks" />
          </SectionHeader>
        ) : null}
        {ready && options.show.notebooks && !library.notebooks.length ? (
          <Empty>{library.errors.notebooks ? 'Could not read notebooks: ' + library.errors.notebooks : 'No notebooks yet.'}</Empty>
        ) : null}
        {options.show.notebooks && notebooks.visible.length ? (
          <PagedList pager={notebooks}>
            {notebooks.visible.map((notebook) => (
              <ItemRow
                key={notebook.uuid}
                title={notebook.title}
                detail={notebook.folder}
                note={sender.noteFor('notebook:' + notebook.uuid)}
                icon={notebookIcon}
                busy={isOpening('notebook:' + notebook.uuid)}
                onPress={() => launch('notebook:' + notebook.uuid, () => openNotebook(extension, notebook))}
                actions={[sendAction('notebook:' + notebook.uuid, notebook.title, notebook.uuid)]}
              />
            ))}
          </PagedList>
        ) : null}

        {options.show.articles ? (
          <SectionHeader title="ARTICLES" addLabel="Open Library" onAdd={() => extension.navigate(LIBRARY_ROUTE)}>
            <PageControls pager={articles} label="articles" />
          </SectionHeader>
        ) : null}
        {noticeFor('articles')}
        {ready && options.show.articles && !library.articles.length ? (
          <Empty>{collectionHint('articles', options.articles, 'articlesCollection', library)}</Empty>
        ) : null}
        {options.show.articles && articles.visible.length ? (
          <PagedList pager={articles}>
            {articles.visible.map((item) => (
              <ItemRow
                key={item.uuid}
                title={item.title}
                detail={itemDetail(item)}
                note={sender.noteFor('article:' + item.uuid)}
                busy={isOpening('article:' + item.uuid)}
                onPress={() => launch('article:' + item.uuid, () => openBook(extension, item))}
                actions={[
                  sendAction('article:' + item.uuid, item.title, item.location),
                  {
                    label: 'Delete ' + item.title,
                    icon: deleteIcon,
                    onPress: () => libraryAction('articles', 'delete it', DELETE_ARTICLE_ACTIONS, item)
                  }
                ]}
              />
            ))}
          </PagedList>
        ) : null}

        {/* Every uncategorized item, below the fold; hidden when there are none. */}
        {library.uncategorized.length ? (
          <SectionHeader title="UNCATEGORIZED" addLabel="Open Library" onAdd={() => extension.navigate(LIBRARY_ROUTE)}>
            <Text size={20} style={styles.pagerText}>
              {library.uncategorized.length}
            </Text>
          </SectionHeader>
        ) : null}
        {noticeFor('uncategorized')}
        {library.uncategorized.length ? (
          <View>
            {library.uncategorized.map((item) => (
              <ItemRow
                key={item.uuid}
                title={item.title}
                detail={itemDetail(item)}
                busy={isOpening('uncategorized:' + item.uuid)}
                onPress={() => launch('uncategorized:' + item.uuid, () => openBook(extension, item))}
                actions={[
                  {
                    label: 'Add ' + item.title + ' to a collection',
                    icon: addToCollectionIcon,
                    onPress: () => libraryAction('uncategorized', 'add it to a collection', SET_ITEM_COLLECTIONS, item)
                  }
                ]}
              />
            ))}
          </View>
        ) : null}
      </ScrollView>
      ) : null}
      </View>
    </KindleProvider>
  );
}

export function activate(extension) {
  extension.log('k4home activated on firmware ' + extension.firmware);
  extension.home.add({ id: 'main', component: K4Home });
}

// Layout units are scaled about 1.8x to device pixels on the Scribe
// (1860 px wide ≈ 1030 units).
const styles = {
  pageScroller: { flex: 1 },
  // Less padding on the right: the page scrollbar sits there.
  page: { paddingLeft: 50, paddingRight: 28, paddingTop: 12, paddingBottom: 40 },
  header: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderBottomWidth: 2,
    borderColor: '#000',
    marginTop: 14,
    // Headers without a "+" button line up with those that have one.
    minHeight: 55,
    paddingBottom: 2
  },
  // No letterSpacing: KPP measures text without it and clips the last glyph.
  sectionTitle: {},
  headerActions: { flexDirection: 'row', alignItems: 'center' },
  pager: { flexDirection: 'row', alignItems: 'center', marginRight: 12 },
  pagerText: { marginRight: 8 },
  disabled: { color: '#999' },
  add: { paddingHorizontal: 10 },
  addGlyph: { lineHeight: 44 },
  empty: { paddingVertical: 10 },
  // Fixed viewport: cover, progress bar and three text lines.
  bookScroller: { height: 316 },
  bookRow: { flexDirection: 'row', paddingTop: 12 },
  book: { width: 158, marginRight: 14, alignItems: 'flex-start' },
  cover: { width: 140, height: 210 },
  coverPlaceholder: {
    borderWidth: 2,
    borderColor: '#000',
    padding: 10,
    justifyContent: 'flex-end'
  },
  placeholderTitle: { fontWeight: 'bold' },
  progressTrack: { width: 140, height: 4, borderWidth: 1, borderColor: '#000', marginTop: 6 },
  progressFill: { height: '100%', backgroundColor: '#000' },
  bookTitle: { fontWeight: 'bold', marginTop: 6 },
  rowIcon: { width: 20, height: 25, marginRight: 14 },
  compactRow: {
    flexDirection: 'row',
    alignItems: 'center',
    borderBottomWidth: 1,
    borderColor: '#000',
    height: ROW_HEIGHT
  },
  compactTitle: { flex: 1 },
  rowMain: { flex: 1, flexDirection: 'row', alignItems: 'center', height: '100%' },
  // Side button (delete / add to collection): a wide tap target, small icon.
  rowAction: { height: '100%', paddingLeft: 18, paddingRight: 6, justifyContent: 'center' },
  rowActionIcon: { width: 24, height: 24 },
  // The scroller clips at its edge, and KPP measures text slightly narrow:
  // the padding keeps the last glyph of right-aligned text visible.
  compactDetail: { marginLeft: 16, paddingRight: 4 },
  meme: { alignItems: 'center', marginLeft: 16 },
  titleText: { fontWeight: 'bold', flexShrink: 1 },
  booksSection: { flexDirection: 'row' },
  booksArea: { flex: 1 },
  // Its own section beside BOOKS; the cover is top-aligned with the book covers.
  calendarColumn: { width: 180, marginLeft: 28 },
  calendar: { paddingTop: 12 },
  calendarCover: { width: 180, height: 270, borderWidth: 2, borderColor: '#000' },
  // Tap feedback (useOpening).
  busyRow: { backgroundColor: '#000', paddingHorizontal: 8 },
  // KPP text paints its own light background; make it black too.
  inverted: { color: '#fff', backgroundColor: '#000' },
  openingLabel: { width: 110 },
  openingCover: { backgroundColor: '#000', alignItems: 'center', justifyContent: 'center' }
};
