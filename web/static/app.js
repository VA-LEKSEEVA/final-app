const form = document.getElementById('form');
const authorInput = document.getElementById('author');
const textInput = document.getElementById('text');
const statusDiv = document.getElementById('status');
const messagesList = document.getElementById('messages');
const emptyState = document.getElementById('empty');
const submitButton = document.getElementById('submit');
const refreshButton = document.getElementById('refresh');

void loadMessages();

form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const author = authorInput.value.trim();
    const text = textInput.value.trim();
    if (!author || !text) {
        setStatus('Заполните оба поля', 'error');
        return;
    }

    setSubmitting(true);
    setStatus('', '');
    try {
        const response = await fetch('/api/messages', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ author, text }),
            signal: AbortSignal.timeout(10000)
        });
        if (!response.ok) {
            throw new Error(await errorMessage(response));
        }
        const msg = await response.json();
        setStatus('Сообщение отправлено!', 'success');
        form.reset();
        prependMessage(msg);
    } catch (err) {
        setStatus(`Ошибка: ${friendlyError(err)}`, 'error');
    } finally {
        setSubmitting(false);
    }
});

refreshButton.addEventListener('click', () => void loadMessages());

async function loadMessages() {
    refreshButton.disabled = true;
    try {
        const res = await fetch('/api/messages', {
            headers: { 'Accept': 'application/json' },
            signal: AbortSignal.timeout(10000)
        });
        if (!res.ok) throw new Error(await errorMessage(res));
        const messages = await res.json();
        if (!Array.isArray(messages)) throw new Error('сервер вернул неверный ответ');
        renderMessages(messages);
    } catch (err) {
        setStatus(`Ошибка загрузки: ${friendlyError(err)}`, 'error');
    } finally {
        refreshButton.disabled = false;
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
    messagesList.prepend(messageElement(message));
}

function messageElement(message) {
    const item = document.createElement('li');
    const author = document.createElement('div');
    const text = document.createElement('p');
    const time = document.createElement('time');
    const date = new Date(message.created_at);

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

function setStatus(text, type) {
    statusDiv.textContent = text;
    statusDiv.className = type ? `status ${type}` : 'status';
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
    if (error instanceof DOMException && error.name === 'TimeoutError') {
        return 'сервер не ответил вовремя';
    }
    return error instanceof Error ? error.message : 'неизвестная ошибка';
}
