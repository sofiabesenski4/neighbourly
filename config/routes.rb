Rails.application.routes.draw do
  post "start-chat", to: "chats#create", as: :start_chat, defaults: {entrypoint: "landing"}
  get "guest-chats/:id", to: "chats#show", as: :guest_chat, defaults: {guest_entry: true}

  resources :chats, only: [:new, :create, :show, :destroy] do
    resources :messages, only: [:create]
    resources :chat_responses, only: [] do
      get :latest, on: :collection
      post :retry, on: :member, action: :retry_response
      post :stop, on: :member
    end
  end
  get "chats", to: redirect("/chats/new", status: 302), as: nil
  resources :models, only: [:index, :show], constraints: {id: /[^\/]+/} do
    collection do
      post :refresh
    end
  end
  devise_for :users, controllers: {
    sessions: "users/sessions",
    registrations: "users/registrations",
    passwords: "users/passwords"
  }

  get "admin", to: "admin#index", as: :admin
  resources :users, only: [:index, :show, :edit, :update, :destroy]
  resources :sources, only: [:index, :show, :new, :create, :destroy]
  resources :documents, except: [:index]
  resources :reports, only: [:index, :create] do
    member do
      patch :dismiss
      patch :validate
    end
  end
  get "printout", to: "flyers#new", as: :new_flyer
  resources :flyers, path: "printout", only: [:create] do
    # POST is for a preview with a location, which shouldn't appear in a URL.
    match :preview, on: :collection, via: [:get, :post]
    post :locate, on: :collection
  end
  # Keep existing builder and HTML preview bookmarks working.
  get "flyers/new", to: "flyers#preview"
  get "flyers/preview", to: "flyers#preview"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
  root to: "pages#home"
end
