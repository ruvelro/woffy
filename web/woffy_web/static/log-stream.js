const output = document.getElementById("log-output");
if (output && window.EventSource) {
  const stream = new EventSource("/logs/stream");
  stream.onmessage = (event) => {
    output.textContent += JSON.parse(event.data) + "\n";
    output.parentElement.scrollTop = output.parentElement.scrollHeight;
  };
}

