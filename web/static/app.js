const form = document.getElementById('form');
const authorInput = document.getElementById('author');
const textInput = document.getElementById('text');
const statusDiv = document.getElementById('status');
const messagesList = document.getElementById('messages');

// Загрузка сообщений при старте
loadMessages();

form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const author = authorInput.value.trim();
    const text = textInput.value.trim();
    if (!author || !text) {
        setStatus('Заполните оба поля', 'error');
        return;
    }
    try {
        const response = await fetch('/api/messages', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ author, text })
        });
        if (!response.ok) {
            const err = await response.text();
            throw new Error(err);
        }
        const msg = await response.json();
        setStatus('Сообщение отправлено!', 'success');
        form.reset();
        loadMessages(); // обновляем список
    } catch (err) {
        setStatus('Ошибка: ' + err.message, 'error');
    }
});

async function loadMessages() {
    try {
        const res = await fetch('/api/messages');
        if (!res.ok) throw new Error('не удалось загрузить');
        const messages = await res.json();
        renderMessages(messages);
    } catch (err) {
        setStatus('Ошибка загрузки: ' + err.message, 'error');
    }
}

function renderMessages(messages) {
    messagesList.innerHTML = '';
    messages.forEach(msg => {
        const li = document.createElement('li');
        const date = new Date(msg.created_at).toLocaleString();
        li.innerHTML = `
            <div class="message-author">${escapeHtml(msg.author)}</div>
            <div class="message-text">${escapeHtml(msg.text)}</div>
            <div class="message-time">${date}</div>
        `;
        messagesList.appendChild(li);
    });
}

function setStatus(text, type) {
    statusDiv.textContent = text;
    statusDiv.style.color = type === 'success' ? 'green' : 'red';
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}
