// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

import LiveCharts from "live_charts"

const currency_formatter = new Intl.NumberFormat('pt-BR', {
    style: 'currency',
    currency: 'BRL'
  }).format;
// const currency_formatter = function (val) { return `R$ ${val}` };
// Override the default ApexCharts hook to inject dataLabels.formatter
const BaseApexHook = LiveCharts.Hooks["LiveCharts.Hooks.ApexCharts"]
const CustomApexHook = {
  ...BaseApexHook,
  // Inject our formatter at config parsing time, then let the base hook render the chart
  getConfig() {
    // Delegate to the base hook's getConfig to keep its parsing/cleanup behavior
    const baseGetConfig = BaseApexHook && typeof BaseApexHook.getConfig === "function"
      ? BaseApexHook.getConfig
      : function () {
          const cfg = JSON.parse(this.el.dataset.chart || "{}")
          delete this.el.dataset.chart
          return cfg
        }
    const config = baseGetConfig.call(this)
    config.dataLabels = config.dataLabels || {}
    config.dataLabels.formatter = currency_formatter;
    config.tooltip = config.tooltip || {}
    config.tooltip.y = {formatter: currency_formatter};
    console.log("config", config)
    return config
  },
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...LiveCharts.Hooks,
    // Override only the ApexCharts hook
    "LiveCharts.Hooks.ApexCharts": CustomApexHook,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

