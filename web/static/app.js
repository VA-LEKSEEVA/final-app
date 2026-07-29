const form = document.getElementById('form');
const authorInput = document.getElementById('author');
const textInput = document.getElementById('text');
const formStatus = document.getElementById('form-status');
const listStatus = document.getElementById('list-status');
const messagesList = document.getElementById('messages');
const emptyState = document.getElementById('empty');
const submitButton = document.getElementById('submit');
const refreshButton = document.getElementById('refresh');
let loadSequence = 0;

void loadMessages();

form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const author = authorInput.value.trim();
    const text = textInput.value.trim();
    if (!author || !text) {
        setStatus(formStatus, 'Заполните оба поля', 'error');
        return;
    }

    setSubmitting(true);
    setStatus(formStatus, '', '');
    try {
        const response = await fetchWithTimeout('/api/messages', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ author, text })
        });
        if (!response.ok) {
            throw new Error(await errorMessage(response));
        }
        const msg = await response.json();
        if (!isMessage(msg)) throw new Error('сервер вернул неверный ответ');
        setStatus(formStatus, 'Сообщение отправлено!', 'success');
        form.reset();
        prependMessage(msg);
    } catch (err) {
        setStatus(formStatus, `Ошибка: ${friendlyError(err)}`, 'error');
    } finally {
        setSubmitting(false);
    }
});

refreshButton.addEventListener('click', () => void loadMessages());

async function loadMessages() {
    const sequence = ++loadSequence;
    refreshButton.disabled = true;
    setStatus(listStatus, 'Загрузка…', '');
    try {
        const res = await fetchWithTimeout('/api/messages', {
            headers: { 'Accept': 'application/json' }
        });
        if (!res.ok) throw new Error(await errorMessage(res));
        const messages = await res.json();
        if (!Array.isArray(messages) || !messages.every(isMessage)) {
            throw new Error('сервер вернул неверный ответ');
        }
        if (sequence !== loadSequence) return;
        renderMessages(messages);
        setStatus(listStatus, '', '');
    } catch (err) {
        if (sequence !== loadSequence) return;
        setStatus(listStatus, `Ошибка загрузки: ${friendlyError(err)}`, 'error');
    } finally {
        if (sequence === loadSequence) refreshButton.disabled = false;
    }
}

function renderMessages(messages) {
    messagesList.replaceChildren();
    emptyState.hidden = messages.length !== 0;
    messages.forEach(msg => {
        messagesList.appendChild(messageElement(msg));
    });
}

function prependMessage(message) {
    emptyState.hidden = true;
    const existing = messagesList.querySelector(`[data-message-id="${message.id}"]`);
    if (existing) existing.remove();
    messagesList.prepend(messageElement(message));
    while (messagesList.children.length > 100) {
        messagesList.lastElementChild?.remove();
    }
}

function messageElement(message) {
    const item = document.createElement('li');
    const author = document.createElement('div');
    const text = document.createElement('p');
    const time = document.createElement('time');
    const date = new Date(message.created_at);

    item.dataset.messageId = String(message.id);
    author.className = 'message-author';
    author.textContent = String(message.author ?? '');
    text.className = 'message-text';
    text.textContent = String(message.text ?? '');
    time.className = 'message-time';
    time.dateTime = Number.isNaN(date.getTime()) ? '' : date.toISOString();
    time.textContent = Number.isNaN(date.getTime())
        ? 'Дата неизвестна'
        : new Intl.DateTimeFormat(undefined, {
            dateStyle: 'medium',
            timeStyle: 'short'
        }).format(date);

    item.append(author, text, time);
    return item;
}

function setStatus(element, text, type) {
    element.textContent = text;
    element.className = type ? `status ${type}` : 'status';
}

function setSubmitting(isSubmitting) {
    submitButton.disabled = isSubmitting;
    submitButton.textContent = isSubmitting ? 'Отправка…' : 'Отправить';
}

async function errorMessage(response) {
    const contentType = response.headers.get('content-type') ?? '';
    if (contentType.includes('application/json')) {
        const payload = await response.json().catch(() => null);
        if (payload && typeof payload.error === 'string') return payload.error;
    }
    const text = await response.text().catch(() => '');
    return text.trim() || `HTTP ${response.status}`;
}

function friendlyError(error) {
    if (error instanceof DOMException && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
        return 'сервер не ответил вовремя';
    }
    return error instanceof Error ? error.message : 'неизвестная ошибка';
}

function isMessage(value) {
    return value !== null
        && typeof value === 'object'
        && Number.isSafeInteger(value.id)
        && value.id > 0
        && typeof value.author === 'string'
        && typeof value.text === 'string'
        && typeof value.created_at === 'string';
}

async function fetchWithTimeout(input, init = {}, timeoutMs = 10000) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
        return await fetch(input, { ...init, signal: controller.signal });
    } finally {
        clearTimeout(timeout);
    }
}
