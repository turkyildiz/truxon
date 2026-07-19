import { Component, type ReactNode } from 'react'
import { errorMessage } from '../supabase'
import { Button } from './ui'

interface Props {
  children: ReactNode
}

interface State {
  error: unknown
}

/** Catches render exceptions below it so one broken page can't white-screen
 * the whole app — the LoadError of thrown errors rather than failed queries.
 * Key it by route so navigating away clears the error without a full reload. */
export default class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: unknown): State {
    return { error }
  }

  render() {
    if (this.state.error != null) {
      return (
        <div className="py-8 text-center">
          <p className="text-sm font-medium text-red-600">Something went wrong — {errorMessage(this.state.error)}</p>
          <Button variant="secondary" className="mt-3" onClick={() => window.location.reload()}>
            Reload
          </Button>
        </div>
      )
    }
    return this.props.children
  }
}
