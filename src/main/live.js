function log() {
  console.log("[Railroad Reloader]", ...arguments);
}

function railroadConnect() {
  let socket = new WebSocket("ws://" + window.location.host + "/ws");

  socket.addEventListener("open", (event) => {
    log("connected");
  });

  // Listen for messages
  socket.addEventListener("message", (event) => {
    const command_end = event.data.indexOf("\n");
    if (command_end == -1) {
      log("failed to find command delimiter in message");
      return;
    }

    const command = event.data.slice(0, command_end);
    const body = event.data.slice(command_end);

    log("command: ", command);

    if (command == "CSS") {
      document.getElementById("__railroad_css").innerHTML = body;
    } else if (command == "BODY") {
      document.body.innerHTML = body;
    }
  });

  socket.addEventListener("close", (event) => {
    log("close", event);
    setTimeout(railroadConnect, 3000);
  });

  socket.addEventListener("error", (event) => {
    log("error", event);
  });
  return socket;
}

railroadConnect();
