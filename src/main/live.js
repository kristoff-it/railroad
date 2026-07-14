function log() {
  console.log("[Railroad Reloader]", ...arguments);
}

let stop = false;
function railroadConnect() {
  log("connect");

  if (stop) {
    log("encountered error, stopping");
    return;
  }
  let socket = new WebSocket("ws://" + window.location.host + "/ws");

  const error = document.getElementById("error");
  const status = document.querySelector(".top-bar .status");
  const status_msg = document.getElementById("status-msg");

  socket.addEventListener("open", (event) => {
    log("connected");
  });

  // Listen for messages
  socket.addEventListener("message", (event) => {
    const command_end = event.data.indexOf("\n");
    if (command_end == -1) {
      log("failed to find command delimiter in message");
      log(event.data);
      return;
    }

    const command = event.data.slice(0, command_end);
    const body = event.data.slice(command_end);

    log("command: ", command);

    if (command == "CSS") {
      document.getElementById("__railroad_css").innerHTML = body;
    } else if (command == "BODY") {
      document.getElementById("main").innerHTML = body;
      error.innerHTML = "";
      activate();
      status_msg.innerText = "Live";
      status.style.fill = "#e5c07b";
      status.style.color = "#e5c07b";
    } else if (command == "ERROR") {
      error.innerHTML = "<pre>" + body + "</pre>";
      status_msg.innerText = "Error";
      status.style.fill = "#e06c75";
      status.style.color = "#e06c75";
    }
  });

  socket.addEventListener("close", (event) => {
    log("close", event);
    status_msg.innerText = "Offline";
    status.style.fill = "#56b6c2";
    status.style.color = "#56b6c2";
    setTimeout(railroadConnect, 3000);
  });

  socket.addEventListener("error", (event) => {
    status_msg.innerText = "Offline";
    status.style.fill = "#56b6c2";
    status.style.color = "#56b6c2";
    log("error", event);
    stop = true;
  });
  return socket;
}

window.onload = railroadConnect;
