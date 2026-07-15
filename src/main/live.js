function log() {
  console.log("[Railroad Reloader]", ...arguments);
}

let stop = false;
let have_body = false;
function railroadConnect() {
  log("connect");

  const error = document.getElementById("error");
  const status = document.querySelector(".top-bar .status");
  const status_msg = document.getElementById("status-msg");

  if (stop) {
    log("encountered error, stopping");
    status_msg.innerText = "Disconnected";
    status.style.fill = "#56b6c2";
    status.style.color = "#56b6c2";
    return;
  }
  let socket = new WebSocket("ws://" + window.location.host + "/ws");

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
      const at_bottom =
        window.innerHeight + Math.round(window.scrollY) >=
        document.body.offsetHeight;

      document.getElementById("main").innerHTML = body;
      error.innerHTML = "";
      activate();
      status_msg.innerText = "Live";
      status.style.fill = "#e5c07b";
      status.style.color = "#e5c07b";

      if (at_bottom && have_body) {
        window.scrollTo(0, document.body.scrollHeight, {
          behavior: "smooth",
        });
      }

      have_body = true;
    } else if (command == "ERROR") {
      error.innerHTML = "<pre>" + body + "</pre>";
      status_msg.innerText = "Build error";
      status.style.fill = "#e06c75";
      status.style.color = "#e06c75";
    }
  });

  socket.addEventListener("close", (event) => {
    log("close", event);
    status_msg.innerText = "Reconnecting";
    status.style.fill = "#56b6c2";
    status.style.color = "#56b6c2";
    setTimeout(railroadConnect, 3000);
  });

  socket.addEventListener("error", (event) => {
    log("error", event);
    stop = true;
  });

  return socket;
}

window.onload = railroadConnect;
