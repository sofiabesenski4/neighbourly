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
  resources :organizations
  resources :services do
    post :confirm, on: :member
  end
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
    # POST keeps questionnaire answers and locations out of preview URLs.
    match :preview, on: :collection, via: [:get, :post]
    post :from_questionnaire, on: :collection, path: "from-questionnaire"
    post :locate, on: :collection
  end
  # The guided questionnaire. GET and POST share one URL, which never holds an answer.
  get "find-help/myself", to: "questionnaires#show", as: :find_help_for_myself
  post "find-help/myself", to: "questionnaires#create"
  # Only says it isn't ready. Point this at the real flow once there is one.
  get "find-help/someone-else", to: "pages#find_help_for_someone_else", as: :find_help_for_someone_else

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
