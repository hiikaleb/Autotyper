let currentConfig = {};
let lastShotPath = "";
let currentCategory = "video";
let currentQuality = "";
const RING_CIRCUMFERENCE = 2 * Math.PI * 86;

/* ---------------------------------------------------------------- */
/* Line icon set (Adobe-style thin stroke icons, replaces emoji)      */
/* ---------------------------------------------------------------- */

const ICONS = {
    download: '<svg viewBox="0 0 24 24"><path d="M12 3v12"/><path d="M6 11l6 6 6-6"/><path d="M4 21h16"/></svg>',
    folder: '<svg viewBox="0 0 24 24"><path d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
    "folder-open": '<svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2H7z"/><path d="M3 7l1.5 11a2 2 0 0 0 2 1.7h10a2 2 0 0 0 2-1.7L20 9H4"/></svg>',
    play: '<svg viewBox="0 0 24 24"><polygon points="6 3 20 12 6 21 6 3"/></svg>',
    puzzle: '<svg viewBox="0 0 24 24"><path d="M9 3h3a1 1 0 0 1 1 1v1.6a1.6 1.6 0 0 0 3.2 0V4a1 1 0 0 1 1-1H19a1 1 0 0 1 1 1v3.8a1 1 0 0 1-1 1h-1.6a1.6 1.6 0 0 0 0 3.2H19a1 1 0 0 1 1 1V16a1 1 0 0 1-1 1h-3a1 1 0 0 1-1-1v-1.6a1.6 1.6 0 0 0-3.2 0V16a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1v-3a1 1 0 0 0-1-1H4.4a1.6 1.6 0 0 1 0-3.2H6a1 1 0 0 0 1-1V4a1 1 0 0 1 1-1z"/></svg>',
    settings: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1 1.55V21a2 2 0 0 1-4 0v-.09A1.7 1.7 0 0 0 9 19.36a1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.7 1.7 0 0 0 4.64 15a1.7 1.7 0 0 0-1.55-1H3a2 2 0 0 1 0-4h.09A1.7 1.7 0 0 0 4.64 9a1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.7 1.7 0 0 0 9 4.64a1.7 1.7 0 0 0 1-1.55V3a2 2 0 0 1 4 0v.09a1.7 1.7 0 0 0 1 1.55 1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.7 1.7 0 0 0 19.36 9a1.7 1.7 0 0 0 1.55 1H21a2 2 0 0 1 0 4h-.09a1.7 1.7 0 0 0-1.51 1z"/></svg>',
    video: '<svg viewBox="0 0 24 24"><rect x="2" y="5" width="14" height="14" rx="2"/><path d="M22 8l-6 4 6 4z"/></svg>',
    music: '<svg viewBox="0 0 24 24"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>',
    image: '<svg viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.6"/><path d="M21 15l-5-5-9 9"/></svg>',
    list: '<svg viewBox="0 0 24 24"><path d="M8 6h13M8 12h13M8 18h13"/><path d="M3 6h.01M3 12h.01M3 18h.01"/></svg>',
    globe: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18z"/></svg>',
    key: '<svg viewBox="0 0 24 24"><circle cx="7.5" cy="15.5" r="4.5"/><path d="M10.6 12.4L20 3M16 7l3 3M14 9l2 2"/></svg>',
    trash: '<svg viewBox="0 0 24 24"><path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/></svg>',
    pencil: '<svg viewBox="0 0 24 24"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
    recycle: '<svg viewBox="0 0 24 24"><path d="M7 19H4.8a1.8 1.8 0 0 1-1.5-2.7l1.7-2.8"/><path d="M13.7 3.4l1.2 2.1M18 12l2 3.4a1.8 1.8 0 0 1-1.5 2.7H15"/><path d="M9 19l2 2 2-2M15 3.4H8.3a1.8 1.8 0 0 0-1.5.9L5.4 6.8"/></svg>',
    clipboard: '<svg viewBox="0 0 24 24"><rect x="6" y="4" width="12" height="16" rx="2"/><rect x="9" y="2" width="6" height="4" rx="1"/></svg>',
    keyboard: '<svg viewBox="0 0 24 24"><rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M6 14h12"/></svg>',
    camera: '<svg viewBox="0 0 24 24"><path d="M4 8h3l2-2h6l2 2h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z"/><circle cx="12" cy="14" r="4"/></svg>',
    "square-select": '<svg viewBox="0 0 24 24"><path d="M4 8V5a1 1 0 0 1 1-1h3M20 8V5a1 1 0 0 0-1-1h-3M4 16v3a1 1 0 0 0 1 1h3M20 16v3a1 1 0 0 1-1 1h-3"/></svg>',
    brain: '<svg viewBox="0 0 24 24"><path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5h1a3 3 0 0 0 2-1"/><path d="M15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5h-1a3 3 0 0 1-2-1"/><path d="M9 4v16M15 4v16"/></svg>',
    refresh: '<svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 3v6h-6"/></svg>',
    "arrow-up": '<svg viewBox="0 0 24 24"><path d="M12 19V5"/><path d="M5 12l7-7 7 7"/></svg>',
    "arrow-left": '<svg viewBox="0 0 24 24"><path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/></svg>',
    plus: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
    file: '<svg viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>',
    stop: '<svg viewBox="0 0 24 24"><rect x="5" y="5" width="14" height="14" rx="1"/></svg>',
    minimize: '<svg viewBox="0 0 24 24"><path d="M5 12h14"/></svg>',
    copy: '<svg viewBox="0 0 24 24"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>',
    pause: '<svg viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>',
    "volume-high": '<svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 5V4L8 9z"/><path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12"/></svg>',
    "volume-mute": '<svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 5V4L8 9z"/><path d="M17 9l5 6M22 9l-5 6"/></svg>',
    "expand": '<svg viewBox="0 0 24 24"><path d="M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3"/></svg>',
};

function ic(name) {
    return `<span class="ic">${ICONS[name] || ""}</span>`;
}

function renderIcons() {
    document.querySelectorAll("[data-i]").forEach(el => {
        el.innerHTML = ic(el.dataset.i);
    });
}

/* ---------------------------------------------------------------- */
/* Sound effects (synthesized, no audio files needed)                 */
/* ---------------------------------------------------------------- */

let audioCtx = null;
function _ctx() {
    if (!audioCtx) {
        const AC = window.AudioContext || window.webkitAudioContext;
        audioCtx = new AC();
    }
    return audioCtx;
}

function _blip(freq, duration, type, gain) {
    if (!currentConfig.typing_sound) return;
    try {
        const ctx = _ctx();
        const osc = ctx.createOscillator();
        const amp = ctx.createGain();
        osc.type = type;
        osc.frequency.value = freq;
        amp.gain.setValueAtTime(gain, ctx.currentTime);
        amp.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + duration);
        osc.connect(amp);
        amp.connect(ctx.destination);
        osc.start();
        osc.stop(ctx.currentTime + duration);
    } catch (e) { /* audio not available, ignore */ }
}

function playKeySound() { _blip(1200 + Math.random() * 300, 0.035, "square", 0.045); }
window.playKeySound = playKeySound;

function playSwitchSound() {
    _blip(500, 0.09, "sine", 0.06);
    setTimeout(() => _blip(760, 0.09, "sine", 0.05), 60);
}
window.playSwitchSound = playSwitchSound;

/* ---------------------------------------------------------------- */
/* Navigation                                                         */
/* ---------------------------------------------------------------- */

function switchView(name) {
    document.querySelectorAll(".view").forEach(v => v.classList.add("hidden"));
    document.getElementById(`view-${name}`).classList.remove("hidden");

    const topLevel = ["downloads", "projects", "extensions"];
    const highlight = topLevel.includes(name) ? name
        : (name.startsWith("ext-") ? "extensions" : name);

    document.querySelectorAll(".tab-btn, .rail-btn").forEach(b => {
        b.classList.toggle("active", b.dataset.view === highlight);
    });

    playSwitchSound();

    if (name === "downloads") maybeFillClipboardUrl();
    if (name === "projects") { loadProjects(); loadActiveProjectLabel(); browseMedia(""); }
    if (name === "ext-memory") refreshMemoryStats();
    if (name === "ext-shots") { syncRecordingStatus(); refreshAudioDevices(); loadRecordingQualityPresets(); }
}
window.switchView = switchView;

async function syncRecordingStatus() {
    const result = await window.pywebview.api.get_recording_status();
    if (result.recording) {
        _setRecordingUI(true);
        document.getElementById("recTimer").textContent = _formatTimer(result.seconds);
        const startedAt = Date.now() - result.seconds * 1000;
        clearInterval(recordingTimerInterval);
        recordingTimerInterval = setInterval(() => {
            document.getElementById("recTimer").textContent = _formatTimer((Date.now() - startedAt) / 1000);
        }, 1000);
    } else {
        _setRecordingUI(false);
    }
}

function showToast(text) {
    const toast = document.getElementById("toast");
    toast.textContent = text;
    toast.classList.add("show");
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => toast.classList.remove("show"), 2500);
}

/* ---------------------------------------------------------------- */
/* Downloads (core)                                                   */
/* ---------------------------------------------------------------- */

const QUALITY_OPTIONS = {
    video: [
        { id: "1080p", label: "1080p (Premiere seguro)" },
        { id: "4k", label: "4K convertido (MP4 H.264)" },
        { id: "best", label: "Melhor qualidade" },
    ],
    audio: [
        { id: "mp3", label: "MP3 320kbps" },
        { id: "original", label: "Melhor qualidade original" },
        { id: "soundcloud", label: "SoundCloud (faixa ou playlist)" },
        { id: "epidemic", label: "Epidemic Sound (login automático)" },
        { id: "direct", label: "Link direto / CDN (arquivo cru)" },
    ],
    thumbnail: [{ id: "default", label: "Padrão" }],
    playlist: [{ id: "default", label: "Vídeo + áudio, MP4" }],
    site: [
        { id: "video", label: "Vídeo + áudio" },
        { id: "audio", label: "Somente áudio (MP3)" },
    ],
};

function selectCategory(cat) {
    currentCategory = cat;
    document.querySelectorAll(".cat-btn").forEach(b => b.classList.toggle("active", b.dataset.cat === cat));

    const grid = document.getElementById("qualityGrid");
    grid.innerHTML = "";
    const opts = QUALITY_OPTIONS[cat] || [];
    opts.forEach((opt, i) => {
        const btn = document.createElement("button");
        btn.className = "quality-opt" + (i === 0 ? " active" : "");
        btn.textContent = opt.label;
        btn.onclick = () => {
            grid.querySelectorAll(".quality-opt").forEach(b => b.classList.remove("active"));
            btn.classList.add("active");
            currentQuality = opt.id;
            updateExtraButtons();
        };
        grid.appendChild(btn);
    });
    currentQuality = opts[0] ? opts[0].id : "";

    document.getElementById("filenameField").style.display = (cat === "video" || cat === "audio" || cat === "site") ? "block" : "none";
    updateExtraButtons();
}
window.selectCategory = selectCategory;

function updateExtraButtons() {
    document.getElementById("epidemicBtn").style.display =
        (currentCategory === "audio" && currentQuality === "epidemic") ? "inline-flex" : "none";
    document.getElementById("formatsBtn").style.display = currentCategory === "video" ? "inline-flex" : "none";
    document.getElementById("sitesBtn").style.display = currentCategory === "site" ? "inline-flex" : "none";
}

window.onEpidemicLoginDone = function (success) {
    showToast(success ? "Login salvo! Já pode baixar do Epidemic Sound." : "Login não foi concluído — tente novamente.");
};

async function showFormats() {
    const url = document.getElementById("dlUrl").value.trim();
    if (!url) { showToast("Cole um link primeiro."); return; }
    showToast("Consultando formatos disponíveis...");
    const result = await window.pywebview.api.list_formats(url);
    if (!result.ok) { showToast(result.message || "Erro ao consultar formatos."); return; }
    alert(result.output || "Nenhum formato encontrado.");
}
window.showFormats = showFormats;

async function showSupportedSites() {
    showToast("Carregando lista de sites suportados...");
    const result = await window.pywebview.api.list_supported_sites();
    if (!result.ok) { showToast(result.message || "Erro ao listar sites."); return; }
    alert((result.sites || []).join("\n"));
}
window.showSupportedSites = showSupportedSites;

async function startDownload() {
    const url = document.getElementById("dlUrl").value.trim();
    if (!url) { showToast("Cole um link primeiro."); return; }

    const filename = document.getElementById("dlFilename").value.trim();

    const result = await window.pywebview.api.start_download(url, currentCategory, currentQuality, filename);
    if (!result.ok) {
        showToast(result.message || "Não foi possível iniciar o download.");
        return;
    }

    if (result.queued) {
        showToast(`Adicionado à fila (posição ${result.position}).`);
        refreshDownloadQueue();
    } else {
        document.getElementById("progressWrap").classList.add("show");
        document.getElementById("progressFill").style.width = "0%";
        document.getElementById("progressMsg").textContent = "Iniciando...";
        document.getElementById("dlStatus").textContent = "Baixando...";
    }
}
window.startDownload = startDownload;

window.onDownloadProgress = function (data) {
    document.getElementById("progressWrap").classList.add("show");
    document.getElementById("dlStatus").textContent = data.done ? "Pronto" : "Baixando...";
    document.getElementById("progressFill").style.width = `${data.percent}%`;
    document.getElementById("progressMsg").textContent = data.message || "";

    if (data.done) {
        document.getElementById("dlStatus").textContent = "Pronto";
        setTimeout(() => document.getElementById("progressWrap").classList.remove("show"), 1500);

        const list = document.getElementById("recentList");
        if (list.children.length === 1 && list.children[0].textContent.includes("Nenhum download")) {
            list.innerHTML = "";
        }
        const item = document.createElement("div");
        item.className = "recent-item";
        item.innerHTML = `<span class="badge ${data.ok ? 'badge-ok' : 'badge-err'}"></span><span>${escapeHtml(data.url || document.getElementById('dlUrl').value.trim())}</span>`;
        list.prepend(item);

        showToast(data.ok ? "Download concluído!" : "Erro no download — clique em \"Ver log\" para detalhes.");
        if (data.ok && data.url === document.getElementById("dlUrl").value.trim()) {
            document.getElementById("dlUrl").value = "";
        }
    }
};

/* ---------------------------------------------------------------- */
/* Download queue                                                     */
/* ---------------------------------------------------------------- */

window.onQueueUpdate = function (state) {
    const wrap = document.getElementById("queueWrap");
    const list = document.getElementById("queueList");

    if (!state.pending || !state.pending.length) {
        wrap.style.display = "none";
        return;
    }

    wrap.style.display = "block";
    list.innerHTML = "";
    state.pending.forEach((job, i) => {
        const item = document.createElement("div");
        item.className = "queue-item";
        item.innerHTML = `
            <span class="queue-pos">#${i + 1}</span>
            <span class="queue-url">${escapeHtml(job.url)}</span>
            <button class="queue-cancel" title="Remover da fila">×</button>
        `;
        item.querySelector(".queue-cancel").onclick = () => cancelQueuedDownload(job.id);
        list.appendChild(item);
    });
};

async function cancelQueuedDownload(jobId) {
    const result = await window.pywebview.api.cancel_queued_download(jobId);
    if (result.ok) showToast("Removido da fila.");
}
window.cancelQueuedDownload = cancelQueuedDownload;

async function refreshDownloadQueue() {
    const state = await window.pywebview.api.get_download_queue();
    window.onQueueUpdate(state);
}

async function maybeFillClipboardUrl() {
    const field = document.getElementById("dlUrl");
    if (field.value.trim()) return; // don't clobber something the user already typed
    const result = await window.pywebview.api.get_clipboard_url();
    if (result.ok && result.url) {
        field.value = result.url;
        showToast("Link da área de transferência preenchido automaticamente.");
    }
}

async function epidemicLogin() {
    showToast("Abrindo login do Epidemic Sound...");
    const result = await window.pywebview.api.capture_epidemic_login();
    if (!result.ok) showToast(result.message || "Não foi possível abrir o login.");
}
window.epidemicLogin = epidemicLogin;

async function runEngineAction(apiMethod, label) {
    showToast(`${label}...`);
    const result = await window.pywebview.api[apiMethod]();
    if (!result.ok) { showToast(result.message || "Não foi possível concluir."); return; }
    showToast(`${label}.`);
}
window.runEngineAction = runEngineAction;

/* ---------------------------------------------------------------- */
/* Projects                                                            */
/* ---------------------------------------------------------------- */

async function loadProjects() {
    const result = await window.pywebview.api.list_projects();
    const grid = document.getElementById("projectGrid");
    grid.querySelectorAll(".project-card:not(.new-project-card)").forEach(c => c.remove());

    if (result.ok) {
        result.projects.forEach(name => {
            const card = document.createElement("button");
            card.className = "project-card" + (name === result.active ? " active" : "");
            card.innerHTML = `
                <div class="p-actions">
                    <button class="p-action p-rename" title="Renomear">${ic('pencil')}</button>
                    <button class="p-action p-delete" title="Excluir">${ic('trash')}</button>
                </div>
                <div class="p-icon">${ic('folder')}</div><div class="p-name">${escapeHtml(name)}</div>` +
                (name === result.active ? `<div class="p-tag">ATIVO</div>` : "");
            card.onclick = () => activateProject(name);
            card.querySelector(".p-rename").onclick = (e) => { e.stopPropagation(); renameProjectPrompt(name); };
            card.querySelector(".p-delete").onclick = (e) => { e.stopPropagation(); deleteProjectPrompt(name); };
            grid.appendChild(card);
        });
    }

    updateActiveProjectLabel(result.active);
    loadActiveProjectLabel();
    browseMedia("");
}

async function activateProject(name) {
    const result = await window.pywebview.api.set_active_project(name);
    if (!result.ok) { showToast(result.message || "Erro."); return; }
    showToast(`Projeto ativo: ${name}`);
    loadProjects();
}

async function createProjectPrompt() {
    const name = prompt("Nome do novo projeto:");
    if (!name) return;
    const result = await window.pywebview.api.create_project(name);
    if (!result.ok) { showToast(result.message || "Erro ao criar projeto."); return; }
    showToast(`Projeto criado: ${result.name}`);
    loadProjects();
}
window.createProjectPrompt = createProjectPrompt;

async function renameProjectPrompt(oldName) {
    const newName = prompt("Novo nome do projeto:", oldName);
    if (!newName || newName === oldName) return;
    const result = await window.pywebview.api.rename_project(oldName, newName);
    if (!result.ok) { showToast(result.message || "Erro ao renomear projeto."); return; }
    showToast(`Projeto renomeado: ${result.name}`);
    loadProjects();
}
window.renameProjectPrompt = renameProjectPrompt;

async function deleteProjectPrompt(name) {
    const sure = confirm(`Excluir o projeto "${name}"? Todos os arquivos dentro dele serão apagados permanentemente.`);
    if (!sure) return;
    const result = await window.pywebview.api.delete_project(name);
    if (!result.ok) { showToast(result.message || "Erro ao excluir projeto."); return; }
    showToast(`Projeto excluído: ${name}`);
    loadProjects();
}
window.deleteProjectPrompt = deleteProjectPrompt;

async function updateActiveProjectLabel(name) {
    document.getElementById("activeProjectLabel").textContent = name || "nenhum";
}

async function openActiveProjectFolder() {
    const result = await window.pywebview.api.open_active_project_folder();
    if (!result.ok) showToast(result.message || "Nenhum projeto ativo.");
}
window.openActiveProjectFolder = openActiveProjectFolder;

async function openDownloadsLog() {
    const result = await window.pywebview.api.open_downloads_log();
    if (!result.ok) showToast(result.message || "Sem log ainda.");
}
window.openDownloadsLog = openDownloadsLog;

async function openCrashLog() {
    const result = await window.pywebview.api.open_crash_log();
    if (!result.ok) showToast(result.message || "Sem log ainda.");
}
window.openCrashLog = openCrashLog;

async function quitApp() {
    if (!confirm("Isso vai fechar o AutoTyper por completo (não fica na bandeja). Continuar?")) return;
    await window.pywebview.api.quit_app();
}
window.quitApp = quitApp;

/* ---------------------------------------------------------------- */
/* Media / player                                                     */
/* ---------------------------------------------------------------- */

async function loadActiveProjectLabel() {
    const active = await window.pywebview.api.get_active_project();
    document.getElementById("mediaProjectLabel").textContent = active.ok ? active.name : "pasta Avulso";
}

async function browseMedia(subpath) {
    const result = await window.pywebview.api.browse_media(subpath);
    if (!result.ok) { showToast(result.message || "Erro ao listar arquivos."); return; }

    document.getElementById("folderCrumbs").textContent = "/" + (result.subpath || "");

    const folderList = document.getElementById("folderList");
    folderList.innerHTML = "";

    if (result.subpath) {
        const up = result.subpath.split("/").slice(0, -1).join("/");
        const upRow = document.createElement("div");
        upRow.className = "folder-row";
        upRow.innerHTML = `<span class="ic ic-folder">${ic('arrow-up')}</span><span>.. voltar</span>`;
        upRow.onclick = () => browseMedia(up);
        folderList.appendChild(upRow);
    }

    result.folders.forEach(f => {
        const row = document.createElement("div");
        row.className = "folder-row";
        row.innerHTML = `<span class="ic ic-folder">${ic('folder')}</span><span>${escapeHtml(f.name)}</span>`;
        row.onclick = () => browseMedia(f.path);
        folderList.appendChild(row);
    });

    const grid = document.getElementById("fileGrid");
    grid.innerHTML = "";
    const kindIcon = { video: "video", audio: "music", image: "image", other: "file" };

    result.files.forEach(file => {
        const card = document.createElement("div");
        card.className = "file-card";
        card.innerHTML = `
            <div class="file-thumb kind-${file.kind}">${ic(kindIcon[file.kind] || "file")}</div>
            <div class="file-name">${escapeHtml(file.name)}</div>
            <div class="file-meta">${file.size_kb} KB</div>
        `;
        card.onclick = () => playFile(file, card);
        grid.appendChild(card);
    });

    if (!result.folders.length && !result.files.length) {
        grid.innerHTML = `<div style="color:var(--muted); font-size:12px; grid-column:1/-1">Pasta vazia.</div>`;
    }
}
window.browseMedia = browseMedia;

async function playFile(file, cardEl) {
    document.querySelectorAll(".file-card").forEach(c => c.classList.remove("playing"));

    const video = document.getElementById("videoPlayer");
    const audioBar = document.getElementById("audioPlayerBar");
    const audio = document.getElementById("audioPlayer");
    const empty = document.getElementById("playerEmpty");

    if (file.kind !== "video" && file.kind !== "audio") {
        showToast("Prévia disponível apenas para vídeo e áudio.");
        return;
    }

    const urlResult = await window.pywebview.api.get_file_url(file.full_path);
    if (!urlResult.ok) { showToast("Não foi possível abrir o arquivo."); return; }

    activeMediaEl = (file.kind === "video") ? video : audio;
    document.getElementById("playerPanel").classList.add("has-media");

    if (file.kind === "video") {
        audioBar.classList.remove("show");
        audio.pause();
        empty.style.display = "none";
        video.style.display = "block";
        video.src = urlResult.url;
        video.play().catch(() => {});
    } else {
        video.pause();
        video.style.display = "none";
        empty.style.display = "none";
        audioBar.classList.add("show");
        document.getElementById("audioFileName").textContent = file.name;
        audio.src = urlResult.url;
        audio.play().catch(() => {});
    }

    if (cardEl) cardEl.classList.add("playing");
}

/* ---------------------------------------------------------------- */
/* Custom player controls (shared by <video> and <audio>)             */
/* ---------------------------------------------------------------- */

let activeMediaEl = null;
let ccSeekDragging = false;
let ccVolumeDragging = false;

function _fmtTime(s) {
    if (!isFinite(s) || s < 0) s = 0;
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${String(sec).padStart(2, "0")}`;
}

function _ccMedia() {
    return activeMediaEl;
}

function togglePlayback() {
    const m = _ccMedia();
    if (!m) return;
    if (m.paused) m.play().catch(() => {}); else m.pause();
}
window.togglePlayback = togglePlayback;

function toggleMute() {
    const m = _ccMedia();
    if (!m) return;
    m.muted = !m.muted;
}
window.toggleMute = toggleMute;

function toggleFullscreen() {
    const video = document.getElementById("videoPlayer");
    if (video.style.display === "none") return; // fullscreen only makes sense for video
    if (document.fullscreenElement) {
        document.exitFullscreen();
    } else {
        video.requestFullscreen().catch(() => {});
    }
}
window.toggleFullscreen = toggleFullscreen;

function _ccSeekTo(clientX) {
    const m = _ccMedia();
    const bar = document.getElementById("ccSeek");
    if (!m || !m.duration) return;
    const rect = bar.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    m.currentTime = ratio * m.duration;
}

function _ccVolumeTo(clientX) {
    const m = _ccMedia();
    const bar = document.getElementById("ccVolume");
    if (!m) return;
    const rect = bar.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    m.volume = ratio;
    m.muted = false;
}

function _ccRefresh() {
    const m = _ccMedia();
    if (!m) return;

    document.getElementById("ccPlayBtn").innerHTML = ic(m.paused ? "play" : "pause");
    document.getElementById("ccCurrentTime").textContent = _fmtTime(m.currentTime);
    document.getElementById("ccDuration").textContent = _fmtTime(m.duration);

    const pct = m.duration ? (m.currentTime / m.duration) * 100 : 0;
    document.getElementById("ccSeekFill").style.width = pct + "%";
    document.getElementById("ccSeekHandle").style.left = pct + "%";

    if (m.buffered && m.buffered.length && m.duration) {
        const bufEnd = m.buffered.end(m.buffered.length - 1);
        document.getElementById("ccSeekBuffered").style.width = (bufEnd / m.duration * 100) + "%";
    }

    const volPct = m.muted ? 0 : m.volume * 100;
    document.getElementById("ccVolumeFill").style.width = volPct + "%";
    document.getElementById("ccVolumeHandle").style.left = volPct + "%";
    document.getElementById("ccMuteBtn").innerHTML = ic((m.muted || m.volume === 0) ? "volume-mute" : "volume-high");
}

function _ccWireMedia(m) {
    ["play", "pause", "timeupdate", "volumechange", "loadedmetadata", "progress"].forEach(evt => {
        m.addEventListener(evt, () => { if (activeMediaEl === m) _ccRefresh(); });
    });
    m.addEventListener("ended", () => {
        if (activeMediaEl === m) {
            document.getElementById("ccPlayBtn").innerHTML = ic("play");
        }
    });
}

document.addEventListener("DOMContentLoaded", () => {
    const video = document.getElementById("videoPlayer");
    const audio = document.getElementById("audioPlayer");
    if (video) _ccWireMedia(video);
    if (audio) _ccWireMedia(audio);

    const seekBar = document.getElementById("ccSeek");
    const volBar = document.getElementById("ccVolume");

    if (seekBar) {
        seekBar.addEventListener("mousedown", e => { ccSeekDragging = true; _ccSeekTo(e.clientX); });
    }
    if (volBar) {
        volBar.addEventListener("mousedown", e => { ccVolumeDragging = true; _ccVolumeTo(e.clientX); });
    }
    window.addEventListener("mousemove", e => {
        if (ccSeekDragging) _ccSeekTo(e.clientX);
        if (ccVolumeDragging) _ccVolumeTo(e.clientX);
    });
    window.addEventListener("mouseup", () => { ccSeekDragging = false; ccVolumeDragging = false; });
});

/* ---------------------------------------------------------------- */
/* Typing extension                                                   */
/* ---------------------------------------------------------------- */

async function loadConfig() {
    currentConfig = await window.pywebview.api.get_config();

    document.getElementById("errorStat").textContent = currentConfig.error_percent + "%";
    document.getElementById("speedStat").textContent = `${currentConfig.min_delay_ms}–${currentConfig.max_delay_ms} ms`;
    document.getElementById("shotStat").textContent = currentConfig.screenshot_hotkey.toUpperCase();
    document.getElementById("shotsFolderLabel").textContent = (currentConfig.screenshot_folder || "screenshots") + "/";
}

function updateCounter() {
    const text = document.getElementById("text").value;
    document.getElementById("counter").textContent = `${text.length} caracteres`;
}
window.updateCounter = updateCounter;

function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
}

async function startTyping() {
    const text = document.getElementById("text").value;
    if (!text.trim()) { showToast("Digite um texto primeiro."); return; }
    const result = await window.pywebview.api.start(text);
    showToast(result.ok ? "Posicione o cursor no destino. Começando em 1 segundo..." : (result.message || "Não foi possível iniciar."));
}
window.startTyping = startTyping;

async function stopTyping() { await window.pywebview.api.stop(); }
window.stopTyping = stopTyping;

async function minimizeToTray() { await window.pywebview.api.minimize_to_tray(); }
window.minimizeToTray = minimizeToTray;

/* ---------------------------------------------------------------- */
/* Screenshot extension                                               */
/* ---------------------------------------------------------------- */

async function takeScreenshot() {
    const result = await window.pywebview.api.take_screenshot();
    handleShotResult(result, "Screenshot salvo.");
}
window.takeScreenshot = takeScreenshot;

async function takeScreenshotRegion() {
    showToast("Arraste na tela para selecionar a área...");
    const result = await window.pywebview.api.take_screenshot_region();
    handleShotResult(result, "Screenshot da área salvo.");
}
window.takeScreenshotRegion = takeScreenshotRegion;

function handleShotResult(result, okMessage) {
    if (!result.ok) { showToast(result.message || "Erro ao tirar screenshot."); return; }
    showToast(okMessage);
    lastShotPath = result.file || "";

    const thumb = document.getElementById("shotThumb");
    if (result.thumbnail) thumb.innerHTML = `<img src="data:image/png;base64,${result.thumbnail}" alt="preview">`;

    document.getElementById("shotMetaEmpty").classList.add("hidden");
    const nameEl = document.getElementById("shotFileName");
    nameEl.textContent = lastShotPath;
    nameEl.classList.remove("hidden");
    document.getElementById("shotMetaActions").style.display = "flex";
}

async function copyLastShotPath() {
    if (!lastShotPath) return;
    await window.pywebview.api.copy_to_clipboard(lastShotPath);
    showToast("Caminho copiado.");
}
window.copyLastShotPath = copyLastShotPath;

async function openScreenshotsFolder() {
    const result = await window.pywebview.api.open_screenshots_folder();
    if (!result.ok) showToast(result.message || "Não foi possível abrir a pasta.");
}
window.openScreenshotsFolder = openScreenshotsFolder;

/* ---------------------------------------------------------------- */
/* Screen recording                                                   */
/* ---------------------------------------------------------------- */

let recordingTimerInterval = null;

function _formatTimer(seconds) {
    const m = Math.floor(seconds / 60).toString().padStart(2, "0");
    const s = Math.floor(seconds % 60).toString().padStart(2, "0");
    return `${m}:${s}`;
}

function _setRecordingUI(isRecording) {
    document.getElementById("recIndicator").classList.toggle("hidden", !isRecording);
    document.getElementById("recStopBtn").classList.toggle("hidden", !isRecording);
    document.getElementById("recCancelBtn").classList.toggle("hidden", !isRecording);
    document.getElementById("recFullBtn").disabled = isRecording;
    document.getElementById("recRegionBtn").disabled = isRecording;
}

async function cancelRecording() {
    if (!confirm("Descartar a gravação atual? O arquivo não será salvo.")) return;
    clearInterval(recordingTimerInterval);
    _setRecordingUI(false);
    const result = await window.pywebview.api.cancel_screen_recording();
    showToast(result.ok ? "Gravação descartada." : (result.message || "Erro ao descartar."));
}
window.cancelRecording = cancelRecording;

let _audioDeviceCache = null;

async function refreshAudioDevices(force) {
    const select = document.getElementById("recAudioDevice");
    const previous = select.value;

    // Listing dshow devices means spawning ffmpeg and waiting on it, which
    // takes a noticeable beat. Cache it for the session instead of
    // re-running that every time this panel opens — only the explicit
    // "ATUALIZAR LISTA DE ÁUDIO" button forces a fresh scan.
    let result;
    if (!force && _audioDeviceCache) {
        result = _audioDeviceCache;
    } else {
        result = await window.pywebview.api.list_audio_devices();
        if (result.ok) _audioDeviceCache = result;
    }

    select.innerHTML = `<option value="">Sem áudio</option>`;
    if (result.ok) {
        const list = result.device_list || result.devices.map(name => ({ name, is_loopback: false }));
        list.forEach(d => {
            const opt = document.createElement("option");
            opt.value = d.name;
            opt.textContent = d.label ? `🖥️ ${d.label}` : (d.is_loopback ? `🔊 ${d.name} (áudio do sistema)` : d.name);
            select.appendChild(opt);
        });
        if (previous && result.devices.includes(previous)) select.value = previous;
        if (result.message) showToast(result.message);
    } else if (result.message) {
        showToast(result.message);
    }
}
window.refreshAudioDevices = refreshAudioDevices;

async function loadRecordingQualityPresets() {
    const select = document.getElementById("recQuality");
    if (select.dataset.loaded) return;
    const result = await window.pywebview.api.get_recording_quality_presets();
    if (!result.ok) return;
    select.innerHTML = "";
    result.presets.forEach(p => {
        const opt = document.createElement("option");
        opt.value = p.id;
        opt.textContent = p.label;
        if (p.id === "standard") opt.selected = true;
        select.appendChild(opt);
    });
    select.dataset.loaded = "1";
}

async function startRecording(mode) {
    if (mode === "region") showToast("Arraste na tela para selecionar a área a gravar...");
    const audioDevice = document.getElementById("recAudioDevice").value || null;
    const quality = document.getElementById("recQuality").value || "standard";
    const result = await window.pywebview.api.start_screen_recording(mode, audioDevice, quality);
    if (!result.ok) { showToast(result.message || "Não foi possível iniciar a gravação."); return; }

    _setRecordingUI(true);
    const startedAt = Date.now();
    document.getElementById("recTimer").textContent = "00:00";
    clearInterval(recordingTimerInterval);
    recordingTimerInterval = setInterval(() => {
        document.getElementById("recTimer").textContent = _formatTimer((Date.now() - startedAt) / 1000);
    }, 1000);

    showToast(audioDevice ? "Gravando tela com áudio..." : "Gravando tela...");
}
window.startRecording = startRecording;

async function stopRecording() {
    clearInterval(recordingTimerInterval);
    _setRecordingUI(false);
    showToast("Finalizando gravação...");

    const result = await window.pywebview.api.stop_screen_recording();
    if (!result.ok) { showToast(result.message || "Não foi possível finalizar a gravação."); return; }

    showToast("Gravação salva.");
    document.getElementById("recPreviewWrap").style.display = "flex";
    document.getElementById("recFileName").textContent = result.file || "";
    if (result.thumbnail) {
        document.getElementById("recThumb").innerHTML = `<img src="data:image/jpeg;base64,${result.thumbnail}" alt="preview">`;
    }
}
window.stopRecording = stopRecording;

/* ---------------------------------------------------------------- */
/* Memory extension                                                   */
/* ---------------------------------------------------------------- */

function setRing(percent) {
    const offset = RING_CIRCUMFERENCE * (1 - percent / 100);
    document.getElementById("ringValue").style.strokeDashoffset = offset;
    document.getElementById("ramPercent").textContent = `${percent.toFixed(0)}%`;
}

async function refreshMemoryStats() {
    const result = await window.pywebview.api.get_memory_stats();
    if (!result.ok) { document.getElementById("memLog").textContent = result.message || "Erro ao ler memória."; return; }
    setRing(result.used_percent);
    document.getElementById("ramTotal").textContent = `${result.total_gb} GB`;
    document.getElementById("ramAvailable").textContent = `${result.available_gb} GB`;
}
window.refreshMemoryStats = refreshMemoryStats;

async function reduceMemory() {
    document.getElementById("memLog").textContent = "Otimizando memória, aguarde...";
    const result = await window.pywebview.api.reduce_memory();
    if (!result.ok) {
        document.getElementById("memLog").textContent = result.message || "Não foi possível otimizar.";
        showToast(result.message || "Erro ao otimizar memória.");
        return;
    }
    document.getElementById("ramFreed").textContent = `${result.freed_mb} MB`;
    document.getElementById("memLastRun").textContent = `Otimizado agora (${result.processes} processos)`;
    document.getElementById("memLog").textContent = `✔ ${result.freed_mb} MB liberados em ${result.processes} processos.`;
    showToast(`Memória otimizada: ${result.freed_mb} MB liberados.`);
    refreshMemoryStats();
}
window.reduceMemory = reduceMemory;

async function runExtra(apiMethod, label) {
    const result = await window.pywebview.api[apiMethod]();
    if (!result.ok) { showToast(result.message || "Não foi possível concluir."); return; }
    let extra = result.freed_mb !== undefined ? ` (${result.freed_mb} MB)` : "";
    showToast(`${label}${extra}.`);
}
window.runExtra = runExtra;

/* ---------------------------------------------------------------- */
/* Hotkey capture: click a field, press the combo, done               */
/* ---------------------------------------------------------------- */

const KEY_NAME_MAP = {
    " ": "space", "Control": "ctrl", "Alt": "alt", "Shift": "shift",
    "Meta": "windows", "Escape": "esc", "PrintScreen": "print screen",
    "ArrowUp": "up", "ArrowDown": "down", "ArrowLeft": "left", "ArrowRight": "right"
};

function _normalizeKey(key) {
    return KEY_NAME_MAP[key] || key.toLowerCase();
}

function setupHotkeyCapture(input) {
    input.addEventListener("focus", () => {
        input.classList.add("recording");
        input.dataset.prevValue = input.value;
        input.value = "Pressione a combinação...";
    });

    input.addEventListener("keydown", (event) => {
        event.preventDefault();
        const parts = [];
        if (event.ctrlKey) parts.push("ctrl");
        if (event.altKey) parts.push("alt");
        if (event.shiftKey) parts.push("shift");
        if (event.metaKey) parts.push("windows");

        const isModifierOnly = ["Control", "Alt", "Shift", "Meta"].includes(event.key);
        if (!isModifierOnly) {
            const keyName = _normalizeKey(event.key);
            if (!parts.includes(keyName)) parts.push(keyName);
            input.value = parts.join("+");
            input.blur();
        } else {
            input.value = [...parts, "..."].join("+");
        }
    });

    // Print Screen (and a few other special keys) never fire "keydown"
    // in Chromium-based webviews on Windows — a known browser
    // limitation, not something we can fix on the keydown side. "keyup"
    // does fire for it, so use it as a fallback: if we're still
    // recording and no key has completed the combo yet, finish it here.
    input.addEventListener("keyup", (event) => {
        if (!input.classList.contains("recording")) return;
        if (!input.value.endsWith("...") && input.value !== "Pressione a combinação...") return;

        event.preventDefault();
        const isModifierOnly = ["Control", "Alt", "Shift", "Meta"].includes(event.key);
        if (isModifierOnly) return;

        const parts = [];
        if (event.ctrlKey) parts.push("ctrl");
        if (event.altKey) parts.push("alt");
        if (event.shiftKey) parts.push("shift");
        if (event.metaKey) parts.push("windows");
        const keyName = _normalizeKey(event.key);
        if (!parts.includes(keyName)) parts.push(keyName);
        input.value = parts.join("+");
        input.blur();
    });

    input.addEventListener("blur", () => {
        input.classList.remove("recording");
        if (!input.value || input.value.endsWith("...") || input.value === "Pressione a combinação...") {
            input.value = input.dataset.prevValue || "";
        }
    });
}

document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".hotkey-input").forEach(setupHotkeyCapture);
    renderIcons();
});

/* ---------------------------------------------------------------- */
/* Settings                                                            */
/* ---------------------------------------------------------------- */

function openSettings() {
    const c = currentConfig;
    document.getElementById("typingSound").checked = c.typing_sound !== false;
    document.getElementById("projectsRoot").value = c.projects_root || "";
    document.getElementById("startHotkey").value = c.start_hotkey;
    document.getElementById("screenshotHotkey").value = c.screenshot_hotkey;
    document.getElementById("screenshotRegionHotkey").value = c.screenshot_region_hotkey || "shift+f8";
    document.getElementById("errorPercent").value = c.error_percent;
    document.getElementById("minDelay").value = c.min_delay_ms;
    document.getElementById("maxDelay").value = c.max_delay_ms;
    document.getElementById("removeError").checked = c.remove_error;
    document.getElementById("addError").checked = c.add_error;
    document.getElementById("swapError").checked = c.swap_error;
    document.getElementById("folder").value = c.screenshot_folder;
    document.getElementById("minimizeToTray").checked = c.minimize_to_tray !== false;
    document.getElementById("startHidden").checked = !!c.start_hidden;
    document.getElementById("startWithWindows").checked = !!c.start_with_windows;
    document.getElementById("autoReduceMemory").checked = !!c.auto_reduce_memory;
    document.getElementById("autoReduceInterval").value = c.auto_reduce_interval_min || 30;
    document.getElementById("autoReduceThreshold").value = c.auto_reduce_threshold_percent || 85;

    document.getElementById("settingsModal").classList.remove("hidden");
}
window.openSettings = openSettings;

function closeSettings() {
    document.getElementById("settingsModal").classList.add("hidden");
}
window.closeSettings = closeSettings;

async function saveSettings() {
    const data = {
        typing_sound: document.getElementById("typingSound").checked,
        projects_root: document.getElementById("projectsRoot").value.trim(),
        start_hotkey: document.getElementById("startHotkey").value.trim(),
        screenshot_hotkey: document.getElementById("screenshotHotkey").value.trim(),
        screenshot_region_hotkey: document.getElementById("screenshotRegionHotkey").value.trim(),
        error_percent: Number(document.getElementById("errorPercent").value),
        min_delay_ms: Number(document.getElementById("minDelay").value),
        max_delay_ms: Number(document.getElementById("maxDelay").value),
        remove_error: document.getElementById("removeError").checked,
        add_error: document.getElementById("addError").checked,
        swap_error: document.getElementById("swapError").checked,
        screenshot_folder: document.getElementById("folder").value.trim(),
        minimize_to_tray: document.getElementById("minimizeToTray").checked,
        start_hidden: document.getElementById("startHidden").checked,
        start_with_windows: document.getElementById("startWithWindows").checked,
        auto_reduce_memory: document.getElementById("autoReduceMemory").checked,
        auto_reduce_interval_min: Number(document.getElementById("autoReduceInterval").value),
        auto_reduce_threshold_percent: Number(document.getElementById("autoReduceThreshold").value)
    };

    const result = await window.pywebview.api.save_config(data);
    if (!result.ok) { showToast(result.message || "Erro ao salvar."); return; }

    currentConfig = result.config;
    await loadConfig();
    closeSettings();
    showToast("Configurações salvas.");
}
window.saveSettings = saveSettings;

async function chooseProjectsRoot() {
    const result = await window.pywebview.api.choose_folder();
    if (result.ok) document.getElementById("projectsRoot").value = result.folder;
}
window.chooseProjectsRoot = chooseProjectsRoot;

/* ---------------------------------------------------------------- */

window.addEventListener("pywebviewready", async () => {
    await loadConfig();
    updateCounter();
    selectCategory("video");
    renderIcons();
    maybeFillClipboardUrl();
    refreshDownloadQueue();

    const active = await window.pywebview.api.get_active_project();
    updateActiveProjectLabel(active.ok ? active.name : null);
});
