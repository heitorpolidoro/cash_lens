// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

const Hooks = {}

Hooks.PieChart = {
    mounted() {
        const payload = this.el.dataset.chart ? JSON.parse(this.el.dataset.chart) : {labels: [], data: [], totals: []}
        const ctx = this.el.getContext('2d')
        if (!window.Chart || !ctx) return
        this.payloadTotals = payload.totals || []
        const colors = payload.labels.map((_, i) => `hsl(${(i * 57) % 360} 70% 55%)`)
        this.chart = new Chart(ctx, {
            type: 'pie',
            data: {
                labels: payload.labels,
                datasets: [{
                    data: payload.data,
                    backgroundColor: colors,
                    borderWidth: 0
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {position: 'right'},
                    tooltip: {
                        callbacks: {
                            label: (ctx) => {
                                const percent = Number(ctx.parsed).toFixed(2)
                                const idx = ctx.dataIndex
                                const total = this.payloadTotals[idx] || 0
                                const totalFmt = Number(total).toLocaleString(undefined, {
                                    style: 'currency',
                                    currency: 'BRL'
                                })
                                return `${ctx.label}: ${percent}% (${totalFmt})`
                            }
                        }
                    }
                }
            }
        })
    },
    updated() {
        if (!this.chart) return
        const payload = this.el.dataset.chart ? JSON.parse(this.el.dataset.chart) : {labels: [], data: [], totals: []}
        this.chart.data.labels = payload.labels
        this.chart.data.datasets[0].data = payload.data
        this.payloadTotals = payload.totals || []
        this.chart.update()
    },
    destroyed() {
        this.chart && this.chart.destroy()
    }
}

Hooks.LineChart = {
    mounted() {
        const payload = this.el.dataset.chart ? JSON.parse(this.el.dataset.chart) : {labels: [], datasets: []}
        const ctx = this.el.getContext('2d')
        if (!window.Chart || !ctx) return
        const datasets = (payload.datasets || []).map((ds, i) => ({
            label: ds.label,
            data: ds.data,
            borderColor: `hsl(${(i * 57) % 360} 70% 45%)`,
            backgroundColor: `hsl(${(i * 57) % 360} 70% 75% / 0.3)`,
            tension: 0.2,
            fill: false
        }))
        this.chart = new Chart(ctx, {
            type: 'line',
            data: {labels: payload.labels, datasets},
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: {mode: 'nearest', intersect: false},
                scales: {
                    y: {beginAtZero: true}
                },
                plugins: {
                    legend: {position: 'bottom'},
                    tooltip: {
                        callbacks: {
                            label: (ctx) => `${ctx.dataset.label}: ${ctx.parsed.y.toLocaleString(undefined, {
                                style: 'currency',
                                currency: 'BRL'
                            })}`
                        }
                    }
                }
            }
        })
    },
    updated() {
        if (!this.chart) return
        const payload = this.el.dataset.chart ? JSON.parse(this.el.dataset.chart) : {labels: [], datasets: []}
        this.chart.data.labels = payload.labels
        this.chart.data.datasets = (payload.datasets || []).map((ds, i) => ({
            label: ds.label,
            data: ds.data,
            borderColor: `hsl(${(i * 57) % 360} 70% 45%)`,
            backgroundColor: `hsl(${(i * 57) % 360} 70% 75% / 0.3)`,
            tension: 0.2,
            fill: false
        }))
        this.chart.update()
    },
    destroyed() {
        this.chart && this.chart.destroy()
    }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: Hooks})

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
