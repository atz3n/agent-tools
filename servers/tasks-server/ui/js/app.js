// ── State ──────────────────────────────────────────────
let allTasks = [];
let projects = [];
let currentView = 'all';
let currentProject = null;
let currentTaskId = null;

const FILTER_KEYS = { project: 'filter-project', status: 'filter-status', due: 'filter-due' };

const API = '/';

// ── Helpers ────────────────────────────────────────────
function api(path, opts = {}) {
  return fetch(API + path, {
    headers: { 'Content-Type': 'application/json', ...opts.headers },
    ...opts,
  }).then(r => r.json().then(d => ({ status: r.status, data: d })));
}

function statusBadge(s) {
  const map = { open: 'badge-open', 'on-hold': 'badge-on-hold', 'in-progress': 'badge-in-progress', done: 'badge-done', closed: 'badge-closed' };
  return `<span class="badge ${map[s] || 'badge-open'}">${s || 'open'}</span>`;
}

function priorityBadge(p) {
  const map = { high: 'badge-high', medium: 'badge-medium', low: 'badge-low' };
  return `<span class="badge ${map[p] || 'badge-medium'}">${p || 'medium'}</span>`;
}

function formatDate(d) {
  if (!d) return '';
  try { return new Date(d + 'Z').toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }); }
  catch { return d; }
}

function dueCategory(dueDate) {
  if (!dueDate) return 'none';
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const due = new Date(dueDate + 'T00:00:00');
  const diff = Math.ceil((due - today) / (1000 * 60 * 60 * 24));
  if (diff < 0) return 'overdue';
  if (diff === 0) return 'today';
  if (diff <= 7) return '7d';
  return 'later';
}

function toast(msg, isError = false) {
  const el = document.createElement('div');
  el.className = 'toast' + (isError ? ' error' : '');
  el.textContent = msg;
  document.getElementById('toast-container').appendChild(el);
  setTimeout(() => el.remove(), 3000);
}

function showConfirm(title, message, onOk) {
  document.getElementById('confirm-title').textContent = title;
  document.getElementById('confirm-message').textContent = message;
  document.getElementById('confirm-overlay').classList.add('open');
  document.getElementById('confirm-ok').onclick = () => { closeConfirm(); onOk(); };
}

function closeConfirm() {
  document.getElementById('confirm-overlay').classList.remove('open');
}

// ── Data loading ───────────────────────────────────────
async function loadData() {
  try {
    const [tasksRes, projRes] = await Promise.all([
      api('tasks'),
      api('projects'),
    ]);
    allTasks = tasksRes.data.tasks || [];
    projects = projRes.data.projects || [];
  } catch (e) {
    toast('Failed to load data: ' + e.message, true);
  }
  renderAll();
}

function renderAll() {
  renderCounts();
  renderProjectSidebar();
  renderProjectFilter();
  renderTasks();
}

// ── Counts ─────────────────────────────────────────────
function renderCounts() {
  document.getElementById('count-all').textContent = allTasks.length;
  document.getElementById('count-open').textContent = allTasks.filter(t => t.status === 'open').length;
  document.getElementById('count-on-hold').textContent = allTasks.filter(t => t.status === 'on-hold').length;
  document.getElementById('count-in-progress').textContent = allTasks.filter(t => t.status === 'in-progress').length;
  document.getElementById('count-done').textContent = allTasks.filter(t => t.status === 'done').length;
  document.getElementById('count-closed').textContent = allTasks.filter(t => t.status === 'closed').length;
}

// ── Sidebar ────────────────────────────────────────────
function setView(view) {
  currentView = view;
  currentProject = null;
  // Clear project dropdown when view is selected
  const projectSel = document.getElementById('filter-project');
  projectSel.value = '';
  localStorage.setItem(FILTER_KEYS.project, '');
  // Sync status dropdown with sidebar view
  const statusSel = document.getElementById('filter-status');
  const viewToStatus = { all: '', open: 'open', 'on-hold': 'on-hold', 'in-progress': 'in-progress', done: 'done', closed: 'closed' };
  statusSel.value = viewToStatus[view] || '';
  localStorage.setItem(FILTER_KEYS.status, statusSel.value);
  renderProjectSidebar();
  syncSidebarFromDropdown();
  renderTasks();
}

function renderProjectSidebar() {
  const container = document.getElementById('project-list');
  const counts = {};
  allTasks.forEach(t => { counts[t.project] = (counts[t.project] || 0) + 1; });

  container.innerHTML = projects.map(p => `
    <div class="sidebar-item ${currentProject === p ? 'active' : ''}" data-project="${p}" onclick="filterProject('${p.replace(/'/g, "\\'")}')">
      <span>${p}</span>
      <span class="sidebar-count">${counts[p] || 0}</span>
    </div>
  `).join('');
}

function filterProject(project) {
  currentProject = currentProject === project ? null : project;
  currentView = 'all';
  // Clear status dropdown when project is selected
  const statusSel = document.getElementById('filter-status');
  statusSel.value = '';
  localStorage.setItem(FILTER_KEYS.status, '');
  // Sync project dropdown with sidebar selection
  const projectSel = document.getElementById('filter-project');
  projectSel.value = currentProject || '';
  localStorage.setItem(FILTER_KEYS.project, projectSel.value);
  renderProjectSidebar();
  syncSidebarFromDropdown();
  renderTasks();
}

// ── Project filter dropdown ────────────────────────────
function renderProjectFilter() {
  const sel = document.getElementById('filter-project');
  const current = localStorage.getItem(FILTER_KEYS.project) || '';
  sel.innerHTML = '<option value="">All Projects</option>' +
    projects.map(p => `<option value="${p}" ${p === current ? 'selected' : ''}>${p}</option>`).join('');
}

function syncSidebarFromDropdown() {
  const statusFilter = document.getElementById('filter-status').value;
  const projectFilter = document.getElementById('filter-project').value;
  const viewItems = document.querySelectorAll('.sidebar-item[data-view]');
  const projectItems = document.querySelectorAll('.sidebar-item[data-project]');

  if (projectFilter) {
    // Project dropdown selected — update state, highlight matching project, clear all views
    currentView = 'all';
    currentProject = projectFilter;
    projectItems.forEach(el => el.classList.toggle('active', el.dataset.project === projectFilter));
    viewItems.forEach(el => el.classList.remove('active'));
  } else if (statusFilter) {
    // Status dropdown selected — update state, highlight matching view, clear all projects
    currentProject = null;
    currentView = statusFilter;
    projectItems.forEach(el => el.classList.remove('active'));
    viewItems.forEach(el => el.classList.toggle('active', el.dataset.view === statusFilter));
  } else {
    // Nothing filtered — update state, highlight "All Tasks", clear all projects
    currentView = 'all';
    currentProject = null;
    projectItems.forEach(el => el.classList.remove('active'));
    viewItems.forEach(el => el.classList.toggle('active', el.dataset.view === 'all'));
  }
}

// ── Task list rendering ────────────────────────────────
function getFilteredTasks() {
  const search = document.getElementById('search-input').value.toLowerCase();
  const statusFilter = document.getElementById('filter-status').value;
  const projectFilter = document.getElementById('filter-project').value;

  let tasks = allTasks;

  // View filter (sidebar)
  if (currentView !== 'all') {
    tasks = tasks.filter(t => t.status === currentView);
  }

  // Project filter (sidebar)
  if (currentProject) {
    tasks = tasks.filter(t => t.project === currentProject);
  }

  // Dropdown filters
  if (statusFilter) {
    tasks = tasks.filter(t => t.status === statusFilter);
  }
  if (projectFilter) {
    tasks = tasks.filter(t => t.project === projectFilter);
  }

  // Search
  if (search) {
    tasks = tasks.filter(t =>
      (t.title || '').toLowerCase().includes(search) ||
      (t.description || '').toLowerCase().includes(search) ||
      (t.tags || []).some(tag => tag.toLowerCase().includes(search)) ||
      String(t.id).includes(search) ||
      ('#' + String(t.id).padStart(3, '0')).toLowerCase().includes(search)
    );
  }

  // Due date filter
  const dueFilter = document.getElementById('filter-due').value;
  if (dueFilter) {
    tasks = tasks.filter(t => dueCategory(t.due_date) === dueFilter);
  }

  // Sort: in-progress first, then open, done, closed, then by id
  const statusOrder = { 'in-progress': 0, open: 1, 'on-hold': 2, done: 3, closed: 4 };
  tasks.sort((a, b) => (statusOrder[a.status] ?? 3) - (statusOrder[b.status] ?? 3) || a.id - b.id);

  return tasks;
}

function renderTasks() {
  const container = document.getElementById('task-list');
  const tasks = getFilteredTasks();

  // Update shown count
  document.getElementById('task-count').textContent = `${tasks.length} / ${allTasks.length} tasks`;

  if (tasks.length === 0) {
    container.innerHTML = `
      <div class="empty-state">
        <svg fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24">
          <path d="M9 12h6m-3-3v6m-7.5 2.25h15a2.25 2.25 0 0 0 2.25-2.25V6.75A2.25 2.25 0 0 0 19.5 4.5h-15A2.25 2.25 0 0 0 2.25 6.75v10.5A2.25 2.25 0 0 0 4.5 19.5z"/>
        </svg>
        <h3>No tasks found</h3>
        <p>Try adjusting your filters or create a new task.</p>
      </div>`;
    return;
  }

  container.innerHTML = tasks.map(t => {
    const overdue = dueCategory(t.due_date) === 'overdue';
    const dueStyle = overdue ? 'color:var(--danger);font-weight:600' : '';
    return `
    <div class="task-card">
      <div class="task-card-main" onclick="openDetail(${t.id})">
        <div class="task-card-title ${['closed', 'done'].includes(t.status) ? 'closed' : ''}">
          <span class="task-id">#${String(t.id).padStart(3, '0')}</span>
          ${escapeHtml(t.title)}
        </div>
        <div class="task-card-meta">
          ${statusBadge(t.status)}
          ${priorityBadge(t.priority)}
          <span class="badge badge-project">${escapeHtml(t.project || 'default')}</span>
          ${t.due_date ? `<span style="${dueStyle}">Due ${formatDate(t.due_date)}</span>` : ''}
          ${(t.tags || []).length ? `<span>${t.tags.map(escapeHtml).join(', ')}</span>` : ''}
        </div>
      </div>
      <button class="btn-icon view-btn" onclick="event.stopPropagation(); openViewModal(${t.id})" title="View full description">
        <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/><path d="M2.458 12C3.732 7.943 7.522 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7Z"/></svg>
      </button>
    </div>`;
  }).join('');
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}

// ── Create modal ───────────────────────────────────────
function openCreateModal() {
  const sel = document.getElementById('create-project');
  const selected = currentProject && projects.includes(currentProject) ? currentProject : 'default';
  sel.innerHTML = projects.map(p => `<option value="${p}" ${p === selected ? 'selected' : ''}>${p}</option>`).join('') +
    `<option value="default" ${selected === 'default' ? 'selected' : ''}>default</option>`;
  document.getElementById('create-title').value = '';
  document.getElementById('create-status').value = 'open';
  document.getElementById('create-priority').value = 'medium';
  document.getElementById('create-due').value = '';
  document.getElementById('create-tags').value = '';
  document.getElementById('create-desc').value = '';
  document.getElementById('create-overlay').classList.add('open');
  setTimeout(() => document.getElementById('create-title').focus(), 100);
}

function closeCreateModal(e) {
  if (e && e.target !== e.currentTarget) return;
  document.getElementById('create-overlay').classList.remove('open');
}

async function createTask() {
  const title = document.getElementById('create-title').value.trim();
  if (!title) { toast('Title is required', true); return; }

  const body = {
    title,
    project: document.getElementById('create-project').value,
    status: document.getElementById('create-status').value,
    priority: document.getElementById('create-priority').value,
    due_date: document.getElementById('create-due').value || null,
    tags: document.getElementById('create-tags').value.split(',').map(s => s.trim()).filter(Boolean),
    description: document.getElementById('create-desc').value.trim(),
  };

  try {
    const { status, data } = await api('tasks', { method: 'POST', body: JSON.stringify(body) });
    if (status === 201) {
      toast('Task created');
      closeCreateModal();
      await loadData();
    } else {
      toast(data.error || 'Failed to create task', true);
    }
  } catch (e) {
    toast('Failed: ' + e.message, true);
  }
}

// ── Create project modal ───────────────────────────────
function openCreateProjectModal() {
  document.getElementById('create-project-name').value = '';
  document.getElementById('create-project-overlay').classList.add('open');
  setTimeout(() => document.getElementById('create-project-name').focus(), 100);
}

function closeCreateProjectModal(e) {
  if (e && e.target !== e.currentTarget) return;
  document.getElementById('create-project-overlay').classList.remove('open');
}

async function createProject() {
  const name = document.getElementById('create-project-name').value.trim();
  if (!name) { toast('Project name is required', true); return; }

  try {
    const { status, data } = await api('projects', { method: 'POST', body: JSON.stringify({ name }) });
    if (status === 201) {
      toast('Project created');
      closeCreateProjectModal();
      await loadData();
      // Select the newly created project in the create modal
      const sel = document.getElementById('create-project');
      const opt = Array.from(sel.options).find(o => o.value === name);
      if (opt) sel.value = name;
    } else {
      toast(data.error || 'Failed to create project', true);
    }
  } catch (e) {
    toast('Failed: ' + e.message, true);
  }
}

// ── Detail panel resize ────────────────────────────────
(function initResize() {
  const handle = document.getElementById('detail-resize-handle');
  const panel = document.querySelector('.detail-panel');
  let isResizing = false;

  handle.addEventListener('mousedown', e => {
    isResizing = true;
    handle.classList.add('active');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
    e.preventDefault();
  });

  document.addEventListener('mousemove', e => {
    if (!isResizing) return;
    const newWidth = window.innerWidth - e.clientX;
    const clamped = Math.max(320, Math.min(newWidth, window.innerWidth - 200));
    panel.style.width = clamped + 'px';
  });

  document.addEventListener('mouseup', () => {
    if (isResizing) {
      isResizing = false;
      handle.classList.remove('active');
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    }
  });
})();

// ── Markdown renderer (zero-dependency) ────────────────
function renderMarkdown(text) {
  if (!text) return '<p style="color:var(--text-secondary);font-style:italic">No description</p>';

  let html = escapeHtml(text);

  // Code blocks (```) — must come before inline code
  html = html.replace(/```([^\n]*)\n([\s\S]*?)```/g, (_, lang, code) => {
    return `<pre><code>${code.trim()}</code></pre>`;
  });

  // Inline code
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');

  // Headings
  html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
  html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
  html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');

  // Horizontal rules
  html = html.replace(/^---$/gm, '<hr>');

  // Bold + italic
  html = html.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>');
  html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');

  // Links
  html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');

  // Blockquotes
  html = html.replace(/^\> (.+)$/gm, '<blockquote>$1</blockquote>');

  // Unordered lists
  html = html.replace(/^- (.+)$/gm, '<li>$1</li>');
  html = html.replace(/((?:<li>.*<\/li>\n?)+)/g, '<ul>$1</ul>');

  // Paragraphs — wrap remaining lines that aren't already wrapped
  html = html.replace(/^(?!<[huplbho]|<\/)(.+)$/gm, '<p>$1</p>');

  // Clean up extra newlines
  html = html.replace(/\n{2,}/g, '');

  return html;
}

// ── View modal (expanded centered view) ────────────────
function openViewModal(id) {
  const task = allTasks.find(t => t.id === id);
  if (!task) return;

  document.getElementById('view-title').textContent = `Task #${String(task.id).padStart(3, '0')} — ${escapeHtml(task.title)}`;

  const body = document.getElementById('view-body');
  body.innerHTML = `
    <div style="display:flex;gap:8px;margin-bottom:20px;flex-wrap:wrap">
      ${statusBadge(task.status)}
      ${priorityBadge(task.priority)}
      <span class="badge badge-project">${escapeHtml(task.project || 'default')}</span>
      ${task.due_date ? `<span style="font-size:13px;color:var(--text-secondary)">Due ${formatDate(task.due_date)}</span>` : ''}
      ${(task.tags || []).length ? `<span style="font-size:13px;color:var(--text-secondary)">${task.tags.map(escapeHtml).join(', ')}</span>` : ''}
    </div>
    <div class="view-description">
      ${renderMarkdown(task.description || '')}
    </div>
    <div style="margin-top:24px;padding-top:16px;border-top:1px solid var(--border);display:flex;justify-content:space-between;font-size:12px;color:var(--text-secondary)">
      <span>Created ${formatDate(task.created_at?.replace('T', ' ').split(' ')[0])}</span>
      <span>Updated ${formatDate(task.updated_at?.replace('T', ' ').split(' ')[0])}</span>
    </div>
  `;

  document.getElementById('view-overlay').classList.add('open');
}

function closeViewModal(e) {
  if (e && e.target !== e.currentTarget) return;
  document.getElementById('view-overlay').classList.remove('open');
}

// ── Detail panel ───────────────────────────────────────
function openDetail(id) {
  const task = allTasks.find(t => t.id === id);
  if (!task) return;
  currentTaskId = id;

  document.getElementById('detail-title').textContent = `Task #${String(task.id).padStart(3, '0')}`;

  const body = document.getElementById('detail-body');
  body.innerHTML = `
    <div class="detail-field">
      <label>Title</label>
      <input type="text" id="detail-title-input" value="${escapeHtml(task.title)}" onchange="updateField('title', this.value)">
    </div>
    <div style="display:flex;gap:12px">
      <div class="detail-field" style="flex:1">
        <label>Status</label>
        <select id="detail-status" onchange="updateField('status', this.value)">
          <option value="open" ${task.status === 'open' ? 'selected' : ''}>Open</option>
          <option value="on-hold" ${task.status === 'on-hold' ? 'selected' : ''}>On Hold</option>
          <option value="in-progress" ${task.status === 'in-progress' ? 'selected' : ''}>In Progress</option>
          <option value="done" ${task.status === 'done' ? 'selected' : ''}>Done</option>
          <option value="closed" ${task.status === 'closed' ? 'selected' : ''}>Closed</option>
        </select>
      </div>
      <div class="detail-field" style="flex:1">
        <label>Priority</label>
        <select id="detail-priority" onchange="updateField('priority', this.value)">
          <option value="low" ${task.priority === 'low' ? 'selected' : ''}>Low</option>
          <option value="medium" ${task.priority === 'medium' ? 'selected' : ''}>Medium</option>
          <option value="high" ${task.priority === 'high' ? 'selected' : ''}>High</option>
        </select>
      </div>
    </div>
    <div style="display:flex;gap:12px">
      <div class="detail-field" style="flex:1">
        <label>Project</label>
        <select id="detail-project" onchange="updateField('project', this.value)">
          ${projects.map(p => `<option value="${p}" ${task.project === p ? 'selected' : ''}>${p}</option>`).join('')}
          <option value="default" ${!task.project || task.project === 'default' ? 'selected' : ''}>default</option>
        </select>
      </div>
      <div class="detail-field" style="flex:1">
        <label>Due Date</label>
        <input type="date" id="detail-due" value="${task.due_date || ''}" onchange="updateField('due_date', this.value || null)">
      </div>
    </div>
    <div class="detail-field">
      <label>Tags</label>
      <div class="detail-tags" id="detail-tags">
        ${(task.tags || []).map(tag => `<span class="tag">${escapeHtml(tag)} <span class="remove-tag" onclick="removeTag('${escapeHtml(tag)}')">&times;</span></span>`).join('')}
      </div>
      <input type="text" id="detail-tags-input" placeholder="Add a tag…" style="margin-top:6px"
        onkeydown="if(event.key==='Enter'){event.preventDefault();addTag()}">
    </div>
    <div class="detail-field">
      <label>Description</label>
      <textarea id="detail-desc" onchange="updateField('description', this.value)">${escapeHtml(task.description || '')}</textarea>
    </div>
    <div class="detail-field">
      <label>Created</label>
      <div class="value">${formatDate(task.created_at?.replace('T', ' ').split(' ')[0])}</div>
    </div>
    <div class="detail-field">
      <label>Updated</label>
      <div class="value">${formatDate(task.updated_at?.replace('T', ' ').split(' ')[0])}</div>
    </div>
  `;

  document.getElementById('detail-footer').innerHTML = `
    <button class="btn btn-danger btn-sm" onclick="deleteTask(${task.id})">Delete</button>
  `;

  document.getElementById('detail-overlay').classList.add('open');
}

function closeDetail(e) {
  if (e && e.target !== e.currentTarget) return;
  document.getElementById('detail-overlay').classList.remove('open');
  currentTaskId = null;
}

async function updateField(field, value) {
  if (!currentTaskId) return;
  try {
    const { status, data } = await api(`tasks/${currentTaskId}`, {
      method: 'PATCH',
      body: JSON.stringify({ [field]: value }),
    });
    if (status === 200) {
      await loadData();
      openDetail(currentTaskId);
    }
  } catch (e) {
    toast(`Failed to update ${field}: ${e.message}`, true);
  }
}

function addTag() {
  const input = document.getElementById('detail-tags-input');
  const tag = input.value.trim();
  if (!tag) return;
  const task = allTasks.find(t => t.id === currentTaskId);
  if (!task) return;
  const tags = [...(task.tags || []), tag];
  input.value = '';
  updateField('tags', tags);
}

function removeTag(tag) {
  const task = allTasks.find(t => t.id === currentTaskId);
  if (!task) return;
  const tags = (task.tags || []).filter(t => t !== tag);
  updateField('tags', tags);
}

async function deleteTask(id) {
  const task = allTasks.find(t => t.id === id);
  if (!task) return;
  showConfirm(
    'Delete Task?',
    `Delete "${task.title}"? This cannot be undone.`,
    async () => {
      try {
        const { status, data } = await api(`tasks/${id}`, { method: 'DELETE' });
        if (status === 200) {
          toast('Task deleted');
          closeDetail();
          await loadData();
        } else {
          toast(data.error || 'Failed to delete', true);
        }
      } catch (e) {
        toast('Failed: ' + e.message, true);
      }
    }
  );
}

// ── Keyboard shortcuts ─────────────────────────────────
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    if (document.getElementById('confirm-overlay').classList.contains('open')) closeConfirm();
    else if (document.getElementById('create-project-overlay').classList.contains('open')) closeCreateProjectModal();
    else if (document.getElementById('view-overlay').classList.contains('open')) closeViewModal();
    else if (document.getElementById('detail-overlay').classList.contains('open')) closeDetail();
    else if (document.getElementById('create-overlay').classList.contains('open')) closeCreateModal();
  }
  if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
    e.preventDefault();
    document.getElementById('search-input').focus();
  }
  if ((e.ctrlKey || e.metaKey) && e.key === 'n') {
    e.preventDefault();
    openCreateModal();
  }
});

// ── Theme ──────────────────────────────────────────────
const THEME_KEY = 'tasks-theme';

function getSystemPrefersDark() {
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function initTheme() {
  const stored = localStorage.getItem(THEME_KEY);
  const isDark = stored === 'dark' || (stored === null && getSystemPrefersDark());
  if (isDark) {
    document.documentElement.classList.add('dark');
  }
  updateThemeIcons();
}

function toggleTheme() {
  document.documentElement.classList.toggle('dark');
  const isDark = document.documentElement.classList.contains('dark');
  localStorage.setItem(THEME_KEY, isDark ? 'dark' : 'light');
  updateThemeIcons();
}

function updateThemeIcons() {
  const isDark = document.documentElement.classList.contains('dark');
  document.getElementById('theme-icon-sun').style.display = isDark ? 'none' : 'block';
  document.getElementById('theme-icon-moon').style.display = isDark ? 'block' : 'none';
}

// ── Filter persistence ─────────────────────────────────

function saveFilter(name, value) {
  localStorage.setItem(FILTER_KEYS[name], value);
}

function restoreFilters() {
  const projectSel = document.getElementById('filter-project');
  const statusSel = document.getElementById('filter-status');
  const dueSel = document.getElementById('filter-due');
  if (projectSel) projectSel.value = localStorage.getItem(FILTER_KEYS.project) || '';
  if (statusSel) statusSel.value = localStorage.getItem(FILTER_KEYS.status) || '';
  if (dueSel) dueSel.value = localStorage.getItem(FILTER_KEYS.due) || '';
  if (projectSel || statusSel) syncSidebarFromDropdown();
}

// ── Init ───────────────────────────────────────────────
initTheme();
restoreFilters();
loadData();
